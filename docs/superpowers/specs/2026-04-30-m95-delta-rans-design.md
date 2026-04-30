# M95 — DELTA_RANS_ORDER0 + Integer-Channel Auto-Defaults + HDF5 Tuning

**Date:** 2026-04-30
**Status:** Approved
**Milestone:** M95 (codec id 11)
**Parent spec:** `2026-04-28-m93-m94-m95-codec-design.md` §3

---

## 1. New codec: DELTA_RANS_ORDER0

### 1.1 Purpose

Sorted-ascending integer channels (primarily `positions`) compress
poorly under raw rANS because the absolute values are large and
uniformly distributed. Delta encoding converts them to small,
concentrated differences that rANS compresses efficiently. At 30×
coverage, typical position deltas are 100–500, which zigzag+varint
encode to 1–2 bytes with a highly skewed byte distribution ideal for
order-0 entropy coding.

### 1.2 Wire format

```
Offset  Size   Field
──────  ─────  ─────────────────────────────
0       4      magic: "DRA0" (0x44 0x52 0x41 0x30)
4       1      version: uint8 = 1
5       1      element_size: uint8 (1 = int8, 4 = int32, 8 = int64)
6       2      reserved: uint8[2] = 0x00 0x00
8       var    body: rANS order-0 encoded byte stream
```

Total header: 8 bytes, followed by a standard rANS order-0 blob
(identical wire format to `codecs/rans.py` with `order=0`).

### 1.3 Encode pipeline

1. **Parse** input `bytes` as little-endian signed integers of
   `element_size` width (int8, int32, or int64).
2. **Delta:** `delta[0] = values[0]`, `delta[i] = values[i] - values[i-1]`.
3. **Zigzag:** Map signed → unsigned:
   `zz = (d << 1) ^ (d >> (bits - 1))` where `bits` is
   `element_size * 8`. Maps small magnitudes to small unsigned values
   (0→0, -1→1, 1→2, -2→3, 2→4, ...).
4. **Varint (unsigned LEB128):** Encode each unsigned integer as 1+
   bytes, 7 bits per byte, MSB = continuation flag. Small deltas
   (0–127) → 1 byte; typical genomic deltas (100–500) → 1–2 bytes.
5. **rANS order-0:** Feed the concatenated varint byte stream through
   the existing `rans.encode(data, order=0)`.
6. **Header:** Prepend the 8-byte DRA0 header.

### 1.4 Decode pipeline

Reverse of encode:

1. **Header:** Validate magic = `DRA0`, version = 1, extract
   `element_size`. Reject unknown versions.
2. **rANS order-0 decode:** `rans.decode(body)` → varint byte stream.
3. **Varint decode:** Parse unsigned LEB128 integers from the byte
   stream. The expected count is `len(original_bytes) / element_size`,
   which equals `rans_decoded_len / avg_varint_len` — but since varint
   is self-delimiting, we simply consume until the byte stream is
   exhausted.
4. **Zigzag decode:** `d = (zz >> 1) ^ -(zz & 1)`.
5. **Prefix sum:** `values[0] = delta[0]`,
   `values[i] = values[i-1] + delta[i]`.
6. **Serialize** as little-endian bytes of the original element width.

### 1.5 Edge cases

- **Empty input** (0 bytes): encode produces header + rANS-encoded
  empty stream. Decode returns empty bytes.
- **Single element:** delta = value itself. Normal path.
- **Non-monotonic input** (e.g., mate_info_pos): still correct —
  zigzag handles negative deltas. Less compressible than monotonic,
  which is why mate_info_pos defaults to plain RANS_ORDER0 instead.
- **int8 element_size:** Primarily for mapping_qualities if
  DELTA_RANS is ever used there (not default, but valid).

---

## 2. Auto-default channel-codec assignments

On **v1.5 candidacy** (same gate as M94.Z: either REF_DIFF auto-
applied on sequences, or any channel carries an explicit v1.5 codec
override), the following integer channels gain automatic codec
defaults. This mirrors CRAM 3.1's automatic per-field compression.

| Channel | Default codec | Id | Rationale |
|---|---|---|---|
| `positions` | DELTA_RANS_ORDER0 | 11 | Sorted ascending; small deltas |
| `flags` | RANS_ORDER0 | 4 | ~5 dominant flag values |
| `mapping_qualities` | RANS_ORDER0 | 4 | Discrete BWA mapq distribution |
| `template_lengths` | RANS_ORDER0 | 4 | Bimodal ±tlen, LE bytes |
| `mate_info_pos` | RANS_ORDER0 | 4 | Non-monotonic; delta unhelpful |
| `mate_info_tlen` | RANS_ORDER0 | 4 | Same distribution as template_lengths |
| `mate_info_chrom` | NAME_TOKENIZED | 8 | Unchanged from M86 Phase F |

Explicit `signal_codec_overrides` entries override these defaults.
The auto-default logic sits alongside the existing M94.Z qualities
auto-default — same code path, extended to cover integer channels.

Channels NOT listed (sequences, qualities, read_names, cigars) retain
their existing auto-default behavior from M86/M93/M94.Z.

---

## 3. HDF5 chunk-size tuning

`WrittenGenomicRun.chunk_size_hint` raised from 1024 to 65536 rows.
Applies to all per-channel datasets (byte channels, integer channels,
and variable-length compound channels).

For 1.78M reads × 12 channels: ~330 chunks total at 65K-row chunks
vs ~21K chunks at 1024-row. Net structural savings: ~3 MB of HDF5
B-tree and chunk-index overhead.

No behavioral change for reads — HDF5 chunk access is transparent.
Existing files with 1024-row chunks continue to read normally.

---

## 4. Enum additions

All three languages gain:

- `DELTA_RANS_ORDER0 = 11`
- `FQZCOMP_NX16_Z = 12` (backfill into ObjC and Java; Python already
  has it)

The ObjC enum must use explicit value assignment (`= 11`) because
codec id 12 (FQZCOMP_NX16_Z) skips over id 11 in the sequential
auto-numbering that NS_ENUM would otherwise apply.

---

## 5. Cross-language conformance fixtures

Canonical `.bin` files generated by the Python reference implementation
and verified byte-exact by ObjC and Java:

| Fixture | Content | Purpose |
|---|---|---|
| `delta_rans_a.bin` | 1000 sorted ascending int64 positions (delta 100–500) | Happy path, typical genomic |
| `delta_rans_b.bin` | 100 uint32 flags (5 dominant values) | Non-delta path via RANS_ORDER0 (control) |
| `delta_rans_c.bin` | Empty input (0 elements) | Edge: empty |
| `delta_rans_d.bin` | Single int64 element | Edge: n=1 |

Fixture locations follow the established pattern:
- Python: `python/tests/fixtures/codecs/`
- ObjC: `objc/Tests/Fixtures/`
- Java: `java/src/test/resources/ttio/codecs/`

---

## 6. Pipeline integration

### 6.1 Read path

`genomic_run.py::_int_channel_array()` gains a new dispatch branch:

```python
if codec_id == int(Compression.DELTA_RANS_ORDER0):
    from .codecs.delta_rans import decode as _dec
    all_bytes = bytes(ds.read(...))
    decoded_bytes = _dec(all_bytes)
    arr = np.frombuffer(decoded_bytes, dtype=dtype_str)
```

ObjC (`TTIOGenomicRun.m`) and Java equivalents mirror this dispatch.

### 6.2 Write path

The auto-default codec selection (in `TTIOSpectralDataset` /
`SpectralDataset` / Java equivalent) is extended to include integer
channels when v1.5 candidacy is met. The channel-to-codec map from
§2 is the lookup table.

### 6.3 Validation

Per-channel allowed-codec maps gain DELTA_RANS_ORDER0 for the
`positions` channel. Validation rejects DELTA_RANS_ORDER0 on non-
integer channels (sequences, qualities, read_names, cigars).

---

## 7. Acceptance gates

- [ ] `delta_rans_{a,b,c,d}.bin` fixtures byte-exact across
      Python / ObjC / Java.
- [ ] Round-trip: `decode(encode(x)) == x` for int8, int32, int64.
- [ ] Auto-default fires on v1.5 runs without explicit overrides.
- [ ] Existing v1.4 files still decode (no regression).
- [ ] Pipeline round-trip: write `.tio` with auto-defaults, read
      back, verify all integer channels byte-exact.
- [ ] All three language test suites pass.
