# HANDOFF — M86 Phase B: Wire rANS into integer channels (positions, flags, mapping_qualities)

**Scope:** Wire `Compression.RANS_ORDER0` and
`Compression.RANS_ORDER1` (M79 codec ids `4` and `5`) into the
three integer channels of `signal_channels/`: `positions`
(int64), `flags` (uint32), `mapping_qualities` (uint8). Defines
the int↔byte serialisation contract that the WORKPLAN's
deferred-Phase-B note flagged as the missing piece. Three
languages (Python reference, ObjC normative, Java parity), with
one cross-language conformance fixture.

**Branch from:** `main` after M86 Phase E docs (`b29bc8f`).

**IP provenance:** Pure integration work + a small int↔byte
serialisation contract. Reuses the M83 rANS codec (already
clean-room, already cross-language conformant). The
serialisation is straightforward little-endian byte packing of
fixed-width integer arrays; no new codec implementation, no
third-party source consulted.

---

## 1. Background and read-side caveat

M82's `signal_channels/` group writes five datasets per run:
- `sequences` (uint8) — per-base ACGT
- `qualities` (uint8) — per-base Phred
- `positions` (int64) — per-read mapping position
- `flags` (uint32) — per-read SAM flags
- `mapping_qualities` (uint8) — per-read MAPQ

But `genomic_index/` ALSO holds copies of `positions`, `flags`,
and `mapping_qualities` (eagerly loaded by `GenomicIndex.read`),
and `GenomicRun.__getitem__` reads from the index, not from
`signal_channels/`:

```python
position = int(self.index.positions[i])
mapq = int(self.index.mapping_qualities[i])
flag = int(self.index.flags[i])
```

So `signal_channels/{positions,flags,mapping_qualities}` are
effectively **write-only** in the current codebase — the M82
read path doesn't consume them. **Phase B compression is
therefore primarily a file-size optimisation; it does not speed
up or slow down read performance.**

This is acceptable scope for Phase B because:

1. The compressed datasets still take less disk space, which
   matters for the 100s-of-MB-per-run scale of real genomic
   data.
2. The dispatch infrastructure (`signal_codec_overrides`
   accepting integer channels, the int↔byte serialisation
   contract, the read-side decode path) is needed for any
   future reader that prefers `signal_channels/` over
   `genomic_index/` (e.g., streaming readers, region queries
   that bypass the index, M89 transport-layer materialisation).
3. Round-trip tests are still meaningful: write through the
   codec, read back through the codec, verify the integer
   array matches.

The companion future scope of "actually wire the read path to
prefer compressed signal_channels over the duplicate index"
remains a separate refactor; Phase B doesn't undertake it.

---

## 2. Design

### 2.1 The int↔byte serialisation contract

For each integer channel, the encoder treats the array as a
flat byte buffer using **little-endian** element packing:

| Channel             | dtype  | element size | byte order      |
|---------------------|--------|--------------|-----------------|
| `positions`         | int64  | 8 bytes      | little-endian   |
| `flags`             | uint32 | 4 bytes      | little-endian   |
| `mapping_qualities` | uint8  | 1 byte       | (endianness n/a) |

The byte buffer is `array.astype('<i8').tobytes()` (or `<u4` /
`<u1`) — i.e., the array is converted to its little-endian
representation if not already, then the contiguous byte buffer
is taken. This buffer is the input to the codec.

For decode, the byte buffer comes out of the codec; the reader
interprets it via `np.frombuffer(decoded, dtype='<i8')` (or
`<u4` / `<u1`) and returns the resulting array.

The dtype is **determined by channel name lookup**, NOT by an
on-disk attribute (Binding Decision §115). This avoids an extra
attribute and matches the existing channel-name-based dispatch
that the per-channel allowed-codec map already uses.

### 2.2 No schema lift required

Unlike Phase E (which lifted `read_names` from compound to flat
uint8), Phase B keeps the dataset as a flat 1-D dataset of the
same shape — just changes the dtype from int64/uint32/uint8 to
uint8 (the codec output bytes) when the override is set.

When `@compression == 0` (no override), the dataset retains its
original integer dtype (int64/uint32/uint8). When
`@compression > 0`, the dataset is uint8 and the bytes are the
codec output; the reader looks up the channel-name → dtype
mapping to deserialise.

### 2.3 Validation extension

The per-channel allowed-codec map gains three new entries:

```python
_ALLOWED_OVERRIDE_CODECS_BY_CHANNEL = {
    "sequences":         {RANS_ORDER0, RANS_ORDER1, BASE_PACK},
    "qualities":         {RANS_ORDER0, RANS_ORDER1, BASE_PACK, QUALITY_BINNED},
    "read_names":        {NAME_TOKENIZED},
    "positions":         {RANS_ORDER0, RANS_ORDER1},   # new in Phase B
    "flags":             {RANS_ORDER0, RANS_ORDER1},   # new in Phase B
    "mapping_qualities": {RANS_ORDER0, RANS_ORDER1},   # new in Phase B
}
```

The integer channels accept ONLY the rANS codecs. BASE_PACK
would silently corrupt the integer data (its 2-bit packing
mangles non-ACGT bytes through the sidecar mask but doesn't
preserve them as int64 elements after decode). QUALITY_BINNED's
8-bin Phred quantisation is wrong-content for integer fields.
NAME_TOKENIZED tokenises strings, not integers.

The error message for an invalid `(channel, codec)` combination
follows the Phase D/E pattern: name the codec, name the
channel, explain why the codec is wrong-content for the
channel.

### 2.4 Write dispatch extension

Extend the existing `_write_byte_channel_with_codec` helper to
accept any uint8 buffer (already does), and add a new sibling
helper `_write_int_channel_with_codec` (or extend the existing
helper to take a dtype hint). Pseudo-code:

```python
def _write_int_channel_with_codec(group, name, data, default_compression,
                                  codec_override):
    if codec_override is None:
        # Existing path: write as int64/uint32/uint8 with HDF5 filter.
        if dtype_for_channel(name) == np.int64:
            _write_int64_channel(group, name, data, default_compression)
        elif dtype_for_channel(name) == np.uint32:
            _write_uint32_channel(group, name, data, default_compression)
        else:  # uint8
            _write_uint8_channel(group, name, data, default_compression)
        return

    if codec_override not in {Compression.RANS_ORDER0, Compression.RANS_ORDER1}:
        raise ValueError(...)  # caught by validation block, defensive

    # Serialise array → little-endian bytes.
    dtype_str = {"positions": "<i8", "flags": "<u4", "mapping_qualities": "<u1"}[name]
    arr = np.asarray(data).astype(dtype_str, copy=False)
    le_bytes = arr.tobytes()

    # Encode through rANS.
    from .codecs.rans import encode as _enc
    order = 0 if codec_override == Compression.RANS_ORDER0 else 1
    encoded = _enc(le_bytes, order=order)

    # Write as flat uint8 dataset with @compression attribute.
    arr_u8 = np.frombuffer(encoded, dtype=np.uint8)
    ds = group.create_dataset(name, Precision.UINT8,
                              length=arr_u8.shape[0],
                              chunk_size=DEFAULT_SIGNAL_CHUNK,
                              compression=None)
    ds.write(arr_u8)
    write_int_attr(ds, "compression", int(codec_override))
```

### 2.5 Read dispatch extension

Add a new helper `_int_channel_array(name)` on `GenomicRun`
that mirrors `_byte_channel_slice` but returns a typed numpy
array:

```python
def _int_channel_array(self, name: str):
    """Return the full integer array for `name`, lazily decoded.

    For codec-compressed integer channels, decode whole-channel
    on first access and interpret as the channel's natural
    dtype. For uncompressed channels, return the dataset
    contents directly.
    """
    cached = self._decoded_int_channels.get(name)
    if cached is not None:
        return cached

    sig = self.group.open_group("signal_channels")
    ds = sig.open_dataset(name)

    codec_id = read_int_attr_or_zero(ds, "compression")
    if codec_id == 0:
        # Uncompressed; just read with the correct dtype.
        dtype = _CHANNEL_DTYPES[name]
        return np.frombuffer(bytes(ds.read(...)), dtype=dtype)

    if codec_id in (Compression.RANS_ORDER0, Compression.RANS_ORDER1):
        from .codecs.rans import decode as _dec
        all_bytes = bytes(ds.read(offset=0, count=ds.length))
        decoded_bytes = _dec(all_bytes)
        dtype = {"positions": "<i8", "flags": "<u4",
                 "mapping_qualities": "<u1"}[name]
        arr = np.frombuffer(decoded_bytes, dtype=dtype)
        self._decoded_int_channels[name] = arr
        return arr

    raise ValueError(f"@compression={codec_id} on integer channel '{name}' is not supported")
```

The cache is `_decoded_int_channels: dict[str, np.ndarray]`,
separate from `_decoded_byte_channels: dict[str, bytes]` and
`_decoded_read_names: list[str] | None`. Per Binding Decision
§116, each cache holds a different value type and they should
not be conflated.

This helper is **callable** but **not currently called** by
`__getitem__` (which uses `self.index.*`). Tests directly
exercise the helper for round-trip verification.

### 2.6 No back-compat shim

Files written with integer-channel overrides have flat uint8
datasets where M82 had int64/uint32/uint8 datasets. Pre-M86
readers that load `signal_channels/positions` expecting int64
will get garbage (the codec output bytes interpreted as
int64). This matches the Phase A/D/E discipline (Binding
Decision §90).

Files without overrides remain identical to M82 / Phase
A/D/E output and round-trip identically through all reader
versions.

---

## 3. Binding Decisions (continued from M86 Phase E §111–§114)

| #   | Decision | Rationale |
|-----|----------|-----------|
| 115 | The original integer dtype is determined by **channel-name lookup** (`positions → int64`, `flags → uint32`, `mapping_qualities → uint8`), NOT by an on-disk attribute. | Avoids an extra attribute. Matches the existing channel-name-based dispatch the validation map already uses. New channels with new dtypes would require updating the channel-dtype constants in all three languages — same maintenance shape as the validation map. |
| 116 | The lazy-decode cache for integer channels is `dict[str, np.ndarray]` — **separate** from `_decoded_byte_channels` (`dict[str, bytes]`) and `_decoded_read_names` (`list[str]`). | Different value types; different deserialisation semantics. Conflating would force a union type and unnecessary type checks in every read path. |
| 117 | Integer channels accept ONLY `RANS_ORDER0` and `RANS_ORDER1` overrides. BASE_PACK / QUALITY_BINNED / NAME_TOKENIZED are rejected. | BASE_PACK's 2-bit packing mangles non-ACGT bytes; QUALITY_BINNED's 8-bin quantisation is for Phred scores; NAME_TOKENIZED tokenises strings. None of the three preserve the integer values. The rANS codecs are content-agnostic byte-stream coders and work correctly on little-endian integer bytes. |
| 118 | Integer arrays are serialised to **little-endian** byte representation before encoding. | Matches HDF5's de facto storage convention (most x86/ARM systems); matches the project's existing internal serialisations (numpress deltas, transport-format payloads). Documented explicitly so big-endian platforms produce identical wire bytes. |
| 119 | Phase B does NOT change `__getitem__` to consume the compressed `signal_channels/` data. The reader still uses `genomic_index/` for per-read access. | The duplicated `signal_channels/` integer datasets are write-only in the current code; Phase B compresses them for file-size reduction without touching the read path. Wiring the read path through the compressed datasets (and dropping the duplicate index storage) is a separate future refactor. |

---

## 4. API surface (no changes for callers; new values accepted)

### 4.1 Python

The `WrittenGenomicRun.signal_codec_overrides` field signature
is unchanged. Callers can now pass `Compression.RANS_ORDER0`
or `Compression.RANS_ORDER1` for `"positions"`, `"flags"`, or
`"mapping_qualities"`:

```python
run = WrittenGenomicRun(
    # ... existing fields ...
    signal_codec_overrides={
        "positions":         Compression.RANS_ORDER1,  # new in Phase B
        "flags":             Compression.RANS_ORDER0,  # new in Phase B
        "mapping_qualities": Compression.RANS_ORDER1,  # new in Phase B
    },
)
```

Mixed overrides (Phase A + D + E + B all at once) work:

```python
signal_codec_overrides={
    "sequences":         Compression.BASE_PACK,
    "qualities":         Compression.QUALITY_BINNED,
    "read_names":        Compression.NAME_TOKENIZED,
    "positions":         Compression.RANS_ORDER1,
    "flags":             Compression.RANS_ORDER0,
    "mapping_qualities": Compression.RANS_ORDER1,
}
```

### 4.2 Objective-C

```objc
writtenRun.signalCodecOverrides = @{
    @"positions":         @(TTIOCompressionRANS_ORDER1),  // new in Phase B
    @"flags":             @(TTIOCompressionRANS_ORDER0),  // new in Phase B
    @"mapping_qualities": @(TTIOCompressionRANS_ORDER1),  // new in Phase B
};
```

### 4.3 Java

```java
writtenRun.setSignalCodecOverrides(Map.of(
    "positions",         Compression.RANS_ORDER1,
    "flags",             Compression.RANS_ORDER0,
    "mapping_qualities", Compression.RANS_ORDER1
));
```

---

## 5. On-disk schema

### 5.1 M82 baseline (no override) — unchanged

```
/study/genomic_runs/<name>/signal_channels/
    positions:         INT64[n_reads]   (HDF5 ZLIB filter)
    flags:             UINT32[n_reads]  (HDF5 ZLIB filter)
    mapping_qualities: UINT8[n_reads]   (HDF5 ZLIB filter)
```

### 5.2 Phase B with rANS override

```
/study/genomic_runs/<name>/signal_channels/
    positions:         UINT8[encoded_length], no HDF5 filter
        @compression: UINT8 = 4 (or 5)
    flags:             UINT8[encoded_length], no HDF5 filter
        @compression: UINT8 = 4 (or 5)
    mapping_qualities: UINT8[encoded_length], no HDF5 filter
        @compression: UINT8 = 4 (or 5)
```

Each codec-compressed dataset has the same name as the M82
version, but the dtype is uint8 and the bytes are the codec
output of the little-endian byte representation of the
original integer array.

The reader detects compression via `@compression > 0`, decodes
the codec stream to bytes, and interprets the bytes as the
channel's natural integer dtype (looked up by channel name per
Binding Decision §115).

---

## 6. Tests

### 6.1 Python — extend `python/tests/test_m86_genomic_codec_wiring.py`

Add 7 new test methods (numbering continues from M86 Phase E
which ended around test #29):

30. **`test_round_trip_positions_rans_order1`** — write a run
    with `signal_codec_overrides={"positions":
    Compression.RANS_ORDER1}` using monotonically-increasing
    int64 values (typical genomic positions). Verify the
    underlying compressed `signal_channels/positions` dataset
    decodes back to the original int64 array. Use the new
    `_int_channel_array("positions")` helper directly (since
    `__getitem__` still uses `self.index.positions`).
31. **`test_round_trip_flags_rans_order0`** — same with
    `flags` (uint32) and order-0.
32. **`test_round_trip_mapping_qualities_rans_order1`** — same
    with `mapping_qualities` (uint8) and order-1.
33. **`test_size_win_positions`** — write a 10000-read run with
    monotonic positions both with and without RANS_ORDER1.
    Verify the compressed dataset is significantly smaller
    (target: < 50% of HDF5-ZLIB baseline; rANS on
    delta-monotonic int64 should win big).
34. **`test_attribute_set_correctly_integer_channels`** — write
    with all three integer overrides; open the file directly
    and verify each compressed dataset has `@compression > 0`
    and dtype uint8.
35. **`test_reject_base_pack_on_positions`** — `signal_codec_overrides=
    {"positions": Compression.BASE_PACK}` raises ValueError at
    write time with a clear message.
36. **`test_reject_quality_binned_on_flags`** — same with
    `(flags, QUALITY_BINNED)`.
37. **`test_round_trip_full_stack`** — write a run with ALL
    SIX channels overridden (sequences=BASE_PACK,
    qualities=QUALITY_BINNED, read_names=NAME_TOKENIZED,
    positions=RANS_ORDER1, flags=RANS_ORDER0,
    mapping_qualities=RANS_ORDER1). Reopen and verify every
    aligned read matches the original input. This exercises
    the full codec stack.

Plus extend `test_cross_language_fixtures` to load the new
fixture.

### 6.2 ObjC — extend `objc/Tests/TestM86GenomicCodecWiring.m`

Same 7 new test cases. Cross-language fixture loaded from
`objc/Tests/Fixtures/genomic/m86_codec_integer_channels.tio`.
Target ≥ 18 new assertions.

### 6.3 Java — extend
`java/src/test/java/global/thalion/ttio/genomics/M86CodecWiringTest.java`

Same 7 new test cases. Cross-language fixture loaded from
`java/src/test/resources/ttio/fixtures/genomic/m86_codec_integer_channels.tio`.

### 6.4 Cross-language conformance fixture

Generate one new fixture from the Python writer:
`python/tests/fixtures/genomic/m86_codec_integer_channels.tio`.
A 100-read run with:
- `positions`: monotonic `i * 1000 + 1000000` for `i in 0..99`,
  encoded with RANS_ORDER1 (delta-encoding wins).
- `flags`: alternating `0x0001` / `0x0083` (paired/unpaired
  pattern), encoded with RANS_ORDER0.
- `mapping_qualities`: `60` for 80% of reads, `0` for 20%,
  encoded with RANS_ORDER1.
- Sequences: `(b"ACGT" * 25) * 100` (default, no override).
- Qualities: bin-centre Phred (default, no override).
- Read names: `[f"r{i}" for i in range(100)]` (default, no
  override).

ObjC and Java construct the same input deterministically and
verify their writer + reader round-trip matches the Python
fixture byte-exact.

---

## 7. Documentation

### 7.1 `docs/format-spec.md`

Update §10.4 trailing summary: integer channels now also
support codec compression for the rANS codecs (Phase B); the
codec-applicability table is now complete for the byte, string,
and integer channels.

Extend §10.5 (or add §10.7) to document the int↔byte
serialisation contract:

> ### 10.7 Integer-channel codec wiring (M86 Phase B)
>
> Integer channels (`positions` int64, `flags` uint32,
> `mapping_qualities` uint8) under `signal_channels/` accept
> `@compression` values of `4` (RANS_ORDER0) or `5`
> (RANS_ORDER1). When set:
>
> - The dataset is stored as flat 1-D `UINT8`, no HDF5 filter.
> - The bytes are the rANS-coded little-endian byte
>   representation of the original integer array.
> - The reader determines the original dtype by channel-name
>   lookup: `positions → int64`, `flags → uint32`,
>   `mapping_qualities → uint8`.
>
> Other codec ids (6 = BASE_PACK, 7 = QUALITY_BINNED, 8 =
> NAME_TOKENIZED) are rejected on integer channels at
> write-time validation.
>
> **Read-side note:** The current M82-derived read path for
> per-read integer fields uses `genomic_index/`, not
> `signal_channels/`. Phase B compression on the integer
> channels under `signal_channels/` is therefore a write-side
> file-size optimisation; it does not currently affect read
> performance. Future readers that prefer `signal_channels/`
> over `genomic_index/` (e.g., streaming readers) will benefit.

### 7.2 `docs/codecs/rans.md`

Add a brief note in §7 ("Wired into / forward references"):
rANS is now wired into integer channels as well as byte channels
(M86 Phase B).

### 7.3 `CHANGELOG.md`

Add M86 Phase B entry under `[Unreleased]`. Update the header.

### 7.4 `WORKPLAN.md`

The M86 section needs Phase B status flipped from DEFERRED to
SHIPPED.

---

## 8. Out of scope

- **Read-path refactor to use `signal_channels/` instead of
  `genomic_index/`.** Separate future scope; would let Phase B
  compression actually affect read performance.
- **Cigars and mate_info codec wiring (Phase C).** No codec
  match yet for these structurally-VL channels; deferred.
- **MS-side wiring.** Genomic-only.

---

## 9. Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `b29bc8f`).
- [ ] All 7 new tests in
      `python/tests/test_m86_genomic_codec_wiring.py` pass.
- [ ] `m86_codec_integer_channels.tio` fixture committed.
- [ ] Validation rejects integer channels with non-rANS codecs.
- [ ] `_int_channel_array(name)` helper round-trips correctly.

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2329
      PASS baseline + 2 pre-existing M38 Thermo failures).
- [ ] 7 new test methods in `TestM86GenomicCodecWiring.m` pass.
- [ ] Cross-language fixture reads byte-exact across all three
      integer channels.
- [ ] ≥ 18 new assertions across the 7 new tests.

### Java
- [ ] All existing tests pass (zero regressions vs the 482/0/0/0
      baseline → ≥ 489/0/0/0 after M86 Phase B).
- [ ] 7 new test methods in `M86CodecWiringTest.java` pass.
- [ ] Cross-language fixture reads byte-exact.

### Cross-Language
- [ ] All three implementations read
      `m86_codec_integer_channels.tio` byte-exact-on-decoded-data
      (every integer array round-trips to the original Python
      input).
- [ ] `docs/format-spec.md` summary updated; new §10.7
      documents the int↔byte serialisation contract.
- [ ] `docs/codecs/rans.md` §7 updated.
- [ ] `CHANGELOG.md` M86 Phase B entry committed.
- [ ] `WORKPLAN.md` M86 Phase B status flipped to SHIPPED.

---

## 10. Gotchas

128. **Little-endian is non-negotiable.** Integer arrays must
     be serialised to LE bytes BEFORE encoding, regardless of
     the host platform's native byte order. Python:
     `arr.astype('<i8').tobytes()`. ObjC: explicit byte-by-byte
     packing or use `htonl`-equivalents adjusted for LE
     (i.e., on x86 `memcpy` works; on big-endian platforms
     swap bytes). Java: `ByteBuffer.allocate(...).order(ByteOrder.LITTLE_ENDIAN)`
     and `putInt`/`putLong`.

129. **The decode result must be re-interpreted as the channel's
     native dtype.** Don't return raw bytes from
     `_int_channel_array("positions")`; return an int64 numpy
     array (or its language equivalent). Channel-name lookup
     determines the dtype.

130. **Integer channels are smaller per-element than typical
     byte channels.** A 1000-read positions channel is 8 KB
     (int64); rANS overhead per stream is ~1 KB minimum
     (frequency table). On very small inputs the codec may
     produce *larger* output than the raw bytes. Tests should
     use realistic sizes (100+ reads). Acknowledge in docs.

131. **`mapping_qualities` is uint8 — no byte-swap needed.**
     The serialisation contract still applies (treat as flat
     byte buffer), but the actual byte conversion is a no-op
     for uint8. The dispatch path is the same as int64/uint32
     for code uniformity, just trivially transparent on the
     element side.

132. **Phase B compresses data the read path doesn't currently
     read.** This is not a bug. The compression saves disk
     space; the read path uses `genomic_index/` for per-read
     integer access. Tests must call `_int_channel_array(...)`
     directly (or open the dataset and verify the @compression
     attribute) — they cannot verify Phase B's effect via
     `aligned_read.position`, which still goes through the
     uncompressed index. Document in test comments.

133. **The full-stack test (#37) is the most likely to surface
     ordering bugs.** Six channels, six codecs, one round-trip.
     If any codec serialisation conflicts with another (e.g.,
     numeric-overflow checks in different code paths), this
     test catches it. Make the test inputs deterministic and
     keep the assertion list short and direct.
