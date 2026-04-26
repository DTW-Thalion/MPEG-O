# HANDOFF — M86: Wire rANS + BASE_PACK into Genomic Signal-Channel Pipeline

**Scope:** Wire the M83 (rANS order-0/1) and M84 (BASE_PACK)
codecs into the genomic signal-channel write and read paths so a
caller can opt a per-channel compression codec into use at write
time and any reader transparently decodes it. Three languages
(Python reference, ObjC normative, Java parity), with
cross-language conformance fixtures: each language must read a
codec-compressed genomic run produced by either of the other two
byte-for-byte identically to the original input.

**Branch from:** `main` after M84 docs (`881be0f`).

**IP provenance:** Same as M83 / M84 — clean-room codec
implementations from prior milestones. M86 is integration work on
top of those primitives; no third-party codec source consulted at
any point.

---

## 1. Background

M82 stores genomic data uncompressed: one ASCII byte per base in
`signal_channels/sequences`, raw Phred bytes in
`signal_channels/qualities`, integer arrays in
`signal_channels/{positions,flags,mapping_qualities}`, and
variable-length strings in `signal_channels/{cigars,read_names}`.

M83 shipped rANS order-0 and order-1 entropy coders as standalone
primitives. M84 shipped BASE_PACK (2-bit ACGT + sidecar mask) the
same way. Both are byte-stream codecs: byte input → byte output,
no slicing, no random access into the encoded stream. Both ship in
`python/src/ttio/codecs/`, `objc/Source/Codecs/`, and
`java/src/main/java/global/thalion/ttio/codecs/`.

The M82 storage path uses `WrittenGenomicRun.signal_compression`
as a single string codec name (`"gzip"` or `"none"`) for the WHOLE
run. The string is funnelled through `_compression_for(...)` to
the HDF5 deflate filter. There is no per-channel codec selection;
there is no path for the M83/M84 internal codecs.

M86 closes that gap for the two byte-array channels — `sequences`
and `qualities`. Integer channels (`positions`, `flags`,
`mapping_qualities`) and variable-length-string channels (`cigars`,
`read_names`) stay on HDF5-filter ZLIB; per-channel codec
selection for those is out of scope (the integer channels would
need an int↔byte serialisation layer; the VL_STRING channels need
the M85 `name-tokenized` codec, which is a separate milestone).

---

## 2. Design

### 2.1 Per-channel `@compression` attribute

Each compressible signal-channel dataset carries a uint8 attribute
`@compression` holding the M79 codec id. Absence or value `0`
(`Compression.NONE`) means the dataset is stored as-is, with the
HDF5 filter pipeline (typically zlib) handling any transparent
compression. Non-zero values 4–6 (`RANS_ORDER0`, `RANS_ORDER1`,
`BASE_PACK`) mean the dataset bytes are the codec output and the
read path must dispatch to the corresponding `decode()` function
before returning data to the caller.

The attribute scheme matches the existing numpress pattern (which
uses `@<channel>_numpress_fixed_point` on the
`signal_channels` group). The difference: numpress encodes its
codec presence implicitly (presence of the attribute), while M86
makes the codec id explicit (the attribute value names the codec).
Numpress is unaffected by M86; the two mechanisms coexist.

### 2.2 Write-path opt-in

`WrittenGenomicRun` gains a new field
`signal_codec_overrides: dict[str, Compression]` (default empty).
For each channel name in the override dict, the writer:

1. Validates the channel is one of `{"sequences", "qualities"}`.
   Reject overrides for any other channel name with a clear error.
2. Validates the codec id is one of
   `{Compression.RANS_ORDER0, Compression.RANS_ORDER1, Compression.BASE_PACK}`.
   Reject any other value.
3. Encodes the raw uint8 buffer through the codec.
4. Writes the encoded bytes as a uint8 dataset of length
   `len(encoded_bytes)`. **No HDF5 filter** is applied (the bytes
   are already entropy-coded; double-compressing wastes CPU for
   no size win).
5. Sets `@compression` on the dataset to the codec id (uint8).

Channels not in the override dict use the existing
`signal_compression` string path (HDF5 deflate via the filter
pipeline).

### 2.3 Read-path dispatch

When opening a `sequences` or `qualities` dataset:

1. Check for the `@compression` attribute.
2. If absent or `0`: existing slice-based read path (no change).
3. If `4`/`5`/`6`: read all dataset bytes, decode through the
   appropriate codec, cache the decoded buffer on the
   `GenomicRun` instance for subsequent slice access.

The cached decoded buffer trades one-time decode cost for
per-read slice cost (which is just a memory view). For sequential
read iteration (the typical genomic workload) this is faster than
filter-on-each-chunk decoding. For random access into a 10M-read
dataset, the decoded buffer is held in RAM — acceptable for
sequence/quality channels (each ≈ N reads × read_length bytes;
typical = a few hundred MB max). Codec output is byte-stream
non-sliceable; this is the intentional tradeoff.

### 2.4 Lazy decode cache

Add a `_decoded_channels: dict[str, bytes]` field to `GenomicRun`
(Python), `TTIOGenomicRun` (ObjC), and `GenomicRun` (Java),
populated on first access. The existing `_signal_dataset(name)`
helper (or its equivalent) checks `@compression` once on first
dataset open and caches the decoded buffer. Subsequent
`__getitem__` calls slice the cached buffer instead of slicing the
HDF5 dataset.

### 2.5 No back-compat shim

This is a write-forward change in the spirit of M80/M82: a v0.12
genomic file written with `signal_codec_overrides` is unreadable
by pre-M86 readers (they will return raw codec bytes when asked
for a base-slice, which decodes to garbage). This is acceptable
because (a) v0.12 is unreleased, (b) the `@compression` attribute
exists specifically so future readers can detect the codec, and
(c) the format-spec already says any reader must respect
`@compression`. Pre-M86 readers can still read M82 files written
without overrides (no `@compression` attribute on the channels →
fall through to the existing path).

---

## 3. Binding Decisions (continued from M84 §80–§85)

| #  | Decision | Rationale |
|----|----------|-----------|
| 86 | Per-channel `@compression` attribute (uint8) on the dataset itself, not on the parent `signal_channels` group. | Each channel's codec is independent. Putting the attribute on the dataset keeps the metadata co-located with its data and matches HDF5 best practice. The numpress attribute lives on the parent group only because it's a pair (codec choice + scaling factor) that the numpress decoder needs together. |
| 87 | Codec-compressed channels are stored **without** an HDF5 filter. The TTI-O codec output is the raw dataset bytes. | rANS and BASE_PACK output is high-entropy; running it through deflate is a CPU loss with negligible (often negative) size benefit. Skipping the filter keeps the dataset bytes match the codec output exactly, which makes cross-language byte-for-byte fixture comparison straightforward. |
| 88 | Per-channel codec selection only for `sequences` and `qualities`. Override for any other channel raises an error. | Integer channels need an int↔byte serialisation layer not specified in M86. VL_STRING channels need M85 codecs. Restricting the surface keeps the milestone tight and the failure mode explicit. |
| 89 | Lazy whole-channel decode on first access; cache on the `GenomicRun` instance. | Codec output is byte-stream non-sliceable. The decode-once-then-slice tradeoff is the right shape for sequential genomic workloads (the common case) and is acceptable for random-access workloads on typical-size sequencing data. |
| 90 | No backward-compatibility shim for pre-M86 readers. v0.12 files with `signal_codec_overrides` are unreadable by pre-M86 implementations. | Write-forward discipline matches M80, M82. The `@compression` attribute scheme exists in the format-spec already; pre-M86 readers that ignore it are non-conformant readers, not valid old readers. |

---

## 4. API extensions

### 4.1 Python — `WrittenGenomicRun`

Add to `python/src/ttio/written_genomic_run.py`:

```python
from .enums import Compression

@dataclass(slots=True)
class WrittenGenomicRun:
    # ... existing fields ...
    signal_compression: str = "gzip"  # unchanged

    # M86: per-channel codec opt-in. Maps channel name to a TTI-O
    # internal codec id. Only "sequences" and "qualities" are
    # accepted; only RANS_ORDER0, RANS_ORDER1, BASE_PACK are
    # accepted as codec values. Channels not in this dict use the
    # existing signal_compression string path.
    signal_codec_overrides: dict[str, Compression] = field(default_factory=dict)
```

### 4.2 Python — `_write_genomic_run` dispatch

In `python/src/ttio/spectral_dataset.py` `_write_genomic_run`,
replace the two relevant lines (currently lines 904–905) with a
helper call:

```python
# Signal channels — these honour run.signal_compression by default.
sc = rg.create_group("signal_channels")
io._write_int64_channel(sc, "positions", run.positions, run.signal_compression)
_write_byte_channel_with_codec(
    sc, "sequences", run.sequences, run.signal_compression,
    run.signal_codec_overrides.get("sequences"),
)
_write_byte_channel_with_codec(
    sc, "qualities", run.qualities, run.signal_compression,
    run.signal_codec_overrides.get("qualities"),
)
io._write_uint32_channel(sc, "flags", run.flags, run.signal_compression)
io._write_uint8_channel(
    sc, "mapping_qualities", run.mapping_qualities, run.signal_compression
)
# ... existing cigars / read_names compound writes follow unchanged ...
```

The helper lives in `python/src/ttio/_hdf5_io.py`:

```python
def _write_byte_channel_with_codec(
    group, name, data, default_compression, codec_override
):
    """Write a uint8 byte channel, optionally through a TTIO codec.

    If codec_override is None, behaves identically to
    _write_uint8_channel (HDF5 filter dispatch).

    If codec_override is RANS_ORDER0/RANS_ORDER1/BASE_PACK,
    encodes the raw bytes and writes them as an unfiltered uint8
    dataset with @compression set to the codec id.
    """
    from .enums import Compression, Precision
    if codec_override is None:
        _write_uint8_channel(group, name, data, default_compression)
        return

    if codec_override == Compression.RANS_ORDER0:
        from .codecs.rans import encode as _enc
        encoded = _enc(bytes(data), order=0)
    elif codec_override == Compression.RANS_ORDER1:
        from .codecs.rans import encode as _enc
        encoded = _enc(bytes(data), order=1)
    elif codec_override == Compression.BASE_PACK:
        from .codecs.base_pack import encode as _enc
        encoded = _enc(bytes(data))
    else:
        raise ValueError(
            f"signal_codec_overrides['{name}'] = {codec_override!r}: "
            "only RANS_ORDER0, RANS_ORDER1, BASE_PACK are supported"
        )

    arr = np.frombuffer(encoded, dtype=np.uint8)
    ds = group.create_dataset(
        name, Precision.UINT8, length=arr.shape[0],
        chunk_size=DEFAULT_SIGNAL_CHUNK,
        compression=None,           # no HDF5 filter — bytes already coded
    )
    ds.write(arr)
    write_int_attr(ds, "compression", int(codec_override))
```

The override-validation (channel name and codec value) lives at
the top of `_write_genomic_run`:

```python
_ALLOWED_OVERRIDE_CHANNELS = frozenset({"sequences", "qualities"})
_ALLOWED_OVERRIDE_CODECS = frozenset({
    Compression.RANS_ORDER0, Compression.RANS_ORDER1, Compression.BASE_PACK,
})

for ch_name, codec in run.signal_codec_overrides.items():
    if ch_name not in _ALLOWED_OVERRIDE_CHANNELS:
        raise ValueError(
            f"signal_codec_overrides: channel '{ch_name}' not supported "
            f"(only sequences and qualities can use TTIO codecs)"
        )
    if Compression(codec) not in _ALLOWED_OVERRIDE_CODECS:
        raise ValueError(
            f"signal_codec_overrides['{ch_name}']: codec {codec!r} "
            "not supported (only RANS_ORDER0, RANS_ORDER1, BASE_PACK)"
        )
```

### 4.3 Python — `GenomicRun` read dispatch

In `python/src/ttio/genomic_run.py`, modify `_signal_dataset` (or
introduce a new `_signal_bytes(name)` helper) to check
`@compression` once and cache:

```python
@dataclass(slots=True)
class GenomicRun:
    # ... existing fields ...
    _decoded_byte_channels: dict[str, bytes] = field(
        default_factory=dict, repr=False, compare=False,
    )

    def _byte_channel_slice(self, name: str, offset: int, count: int) -> bytes:
        """Return bytes [offset, offset+count) for a uint8 channel.

        For codec-compressed channels (@compression > 0), the whole
        channel is decoded once on first access and cached, then
        sliced from memory. For uncompressed channels, the existing
        per-slice HDF5 read path is used.
        """
        cached = self._decoded_byte_channels.get(name)
        if cached is not None:
            return cached[offset:offset + count]

        ds = self._signal_dataset(name)
        codec_id = _read_int_attr_or_zero(ds, "compression")
        if codec_id == 0:
            return bytes(ds.read(offset=offset, count=count))

        # Compressed: read all bytes, decode, cache.
        from .enums import Compression
        all_bytes = bytes(ds.read(offset=0, count=ds.length))
        if codec_id == Compression.RANS_ORDER0:
            from .codecs.rans import decode as _dec
            decoded = _dec(all_bytes)
        elif codec_id == Compression.RANS_ORDER1:
            from .codecs.rans import decode as _dec
            decoded = _dec(all_bytes)
        elif codec_id == Compression.BASE_PACK:
            from .codecs.base_pack import decode as _dec
            decoded = _dec(all_bytes)
        else:
            raise ValueError(
                f"signal_channel '{name}': @compression={codec_id} "
                "is not a supported codec"
            )
        self._decoded_byte_channels[name] = decoded
        return decoded[offset:offset + count]
```

Then in `__getitem__`, replace the two channel-read blocks with
calls to `self._byte_channel_slice("sequences", offset, length)`
and `self._byte_channel_slice("qualities", offset, length)`.

### 4.4 ObjC — same pattern

`TTIOWrittenGenomicRun.h/m` gains a
`@property NSDictionary<NSString *, NSNumber *> *signalCodecOverrides;`
property (NSNumber boxes the Compression int).

`TTIOWrittenGenomicRun.m`'s write path adds the same dispatch. The
helpers go in a new file `objc/Source/Genomics/TTIOGenomicCodec.{h,m}`
or directly in the existing genomics translation unit.

`TTIOGenomicRun.m` gains a `@property NSMutableDictionary<NSString
*, NSData *> *decodedByteChannels;` (private), and the byte-slice
method dispatches identically.

The validation for channel name and codec id mirrors the Python
side (raise via `[NSException raise:...]` or `NSError**` —
whichever the existing API uses; check existing
`TTIOWrittenGenomicRun` for style).

### 4.5 Java — same pattern

`WrittenGenomicRun.java` (Java) gains:

```java
private Map<String, Compression> signalCodecOverrides = Map.of();
public void setSignalCodecOverrides(Map<String, Compression> overrides) { ... }
public Map<String, Compression> getSignalCodecOverrides() { ... }
```

`GenomicRun.java` gains a `private final Map<String, byte[]> decodedByteChannels = new HashMap<>();` and a `byteChannelSlice(name, offset, count)` helper that mirrors the Python design.

The validation throws `IllegalArgumentException` on disallowed
channel/codec.

---

## 5. Wire Format

### 5.1 `@compression` attribute

| Field           | Type   | Notes                                         |
|-----------------|--------|-----------------------------------------------|
| Attribute name  | `compression` | Lowercase, on the channel dataset.   |
| Type            | uint8  | HDF5 native uint8 (`H5T_NATIVE_UINT8`).       |
| Value 0         | NONE   | Equivalent to attribute absent.               |
| Value 4         | RANS_ORDER0 | Dataset bytes are M83 rANS order-0 stream. |
| Value 5         | RANS_ORDER1 | Dataset bytes are M83 rANS order-1 stream. |
| Value 6         | BASE_PACK | Dataset bytes are M84 BASE_PACK stream.    |

When `@compression > 0`:
- The dataset has shape `[encoded_length]` (1D uint8).
- The dataset has no HDF5 filter (`H5P_DEFAULT` or no filter pipeline).
- The dataset bytes ARE the self-contained codec stream from M83 §2 / M84 §2.

### 5.2 Backwards compatibility

A channel with no `@compression` attribute behaves exactly as in
M82: it's a uint8/int64/uint32 dataset with whatever HDF5 filter
the writer chose (typically gzip level 6 or none). M82 readers
silently work unchanged.

A v0.12 file with `@compression > 0` on a channel will fail
gracefully on a pre-M86 reader: the reader sees a uint8 dataset
of unexpected length (the codec output isn't sliceable), and
`AlignedRead.sequence` will surface as garbled bytes for any
read whose offset/length walks past the encoded payload boundary.
This is detected by the v0.12 acceptance tests on the pre-M86
side; the read returns clearly-wrong data rather than silently
corrupting downstream analysis. The `@compression` attribute is
the canonical signal that the dataset needs codec dispatch.

---

## 6. Tests

### 6.1 Python — new file `python/tests/test_m86_genomic_codec_wiring.py`

Eight test cases. Use a small fixture run (10 reads × 100 bp = 1000-byte sequences and qualities channels):

```python
import numpy as np
import pytest
import tempfile
from pathlib import Path
from ttio.enums import Compression, AcquisitionMode
from ttio.spectral_dataset import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun

def _make_run(seq_bytes: bytes, qual_bytes: bytes,
              codec_overrides=None) -> WrittenGenomicRun:
    n = 10
    read_len = 100
    return WrittenGenomicRun(
        acquisition_mode=AcquisitionMode.GENOMIC_WGS.value,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="M86_TEST",
        positions=np.arange(n, dtype=np.int64) * 1000,
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.zeros(n, dtype=np.uint32),
        sequences=np.frombuffer(seq_bytes, dtype=np.uint8),
        qualities=np.frombuffer(qual_bytes, dtype=np.uint8),
        offsets=np.arange(n, dtype=np.uint64) * read_len,
        lengths=np.full(n, read_len, dtype=np.uint32),
        cigars=["100M"] * n,
        read_names=[f"r{i}" for i in range(n)],
        mate_chromosomes=["chr1"] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1"] * n,
        signal_codec_overrides=codec_overrides or {},
    )
```

Tests:

1. **`test_round_trip_sequences_rans_order0`** — write a run with
   `signal_codec_overrides={"sequences": Compression.RANS_ORDER0}`.
   Reopen, iterate all 10 reads, verify each `aligned_read.sequence`
   matches the corresponding 100-byte slice of the input.
2. **`test_round_trip_sequences_rans_order1`** — same with order-1.
3. **`test_round_trip_sequences_base_pack`** — same with BASE_PACK.
   Use pure-ACGT sequences so the codec compresses well.
4. **`test_round_trip_qualities_rans_order1`** — same on qualities
   channel (Phred bytes have local correlation, so order-1 is
   the natural choice).
5. **`test_round_trip_mixed`** — both overrides at once: BASE_PACK
   on sequences, RANS_ORDER1 on qualities. Round-trip both.
6. **`test_back_compat_no_overrides`** — write with empty
   `signal_codec_overrides`, reopen with M86 read code, verify the
   data round-trips through the existing HDF5-filter path
   unchanged. Confirms the new code path doesn't break M82
   behaviour.
7. **`test_reject_invalid_channel`** — `signal_codec_overrides=
   {"positions": Compression.RANS_ORDER0}` must raise `ValueError`
   at write time (positions is an integer channel).
8. **`test_reject_invalid_codec`** — `signal_codec_overrides=
   {"sequences": Compression.LZ4}` must raise `ValueError` at
   write time (LZ4 is an HDF5 filter, not a TTIO codec).
9. **`test_attribute_set_correctly`** — write with each codec,
   open the underlying h5py file directly, verify the dataset
   has `@compression == codec.value`.
10. **`test_size_win_base_pack`** — write a 100 000 base pure-ACGT
    sequences channel both with and without BASE_PACK; check that
    the BASE_PACK file's `signal_channels/sequences` dataset is
    < 30% the size of the uncompressed dataset.

### 6.2 Cross-language fixture generation

After tests pass, generate three conformance fixtures from the
Python writer in
`python/tests/fixtures/genomic/m86_codec_<codec>.tio`:

```python
# Common input: 10 reads × 100 bp pure-ACGT
seq = (b"ACGT" * 25) * 10           # 1000 bytes pure ACGT
qual = bytes((30 + (i % 11)) for i in range(1000))   # Phred 30-40

for codec_name, codec in [
    ("rans_order0", Compression.RANS_ORDER0),
    ("rans_order1", Compression.RANS_ORDER1),
    ("base_pack",   Compression.BASE_PACK),
]:
    overrides = {"sequences": codec, "qualities": codec}
    # Build run, write to tmpfile, copy to fixtures/
    ...
```

Commit the three `.tio` files as
`python/tests/fixtures/genomic/m86_codec_{rans_order0,rans_order1,base_pack}.tio`.
Total fixture size should be a few hundred KB.

Add an 11th test:
- **`test_cross_language_fixtures`** — for each of the three
  fixture files, open with the M86 Python read path and verify
  every read's sequence and qualities match the known input
  (`b"ACGT" * 25` for each sequence, Phred 30-40 cycle for each
  qualities slice).

### 6.3 ObjC — new file `objc/Tests/TestM86GenomicCodecWiring.m`

Same coverage as Python tests 1–11. Style mirrors
`TestM82GenomicRun.m` (existing genomic test pattern). Loads
fixtures from `objc/Tests/Fixtures/genomic/m86_codec_*.tio`
(verbatim copies of the Python-generated fixtures). Target ≥ 30
new assertions across the 11 tests. Wire into `TTIOTestRunner.m`
as `START_SET("M86: codec wiring") testM86GenomicCodecWiring();
END_SET("M86: codec wiring")`.

Add `objc/Tests/Fixtures/genomic/` directory if it does not
already exist.

### 6.4 Java — new file `java/src/test/java/global/thalion/ttio/genomics/M86CodecWiringTest.java`

Same coverage as Python tests 1–11. JUnit 5. Style mirrors any
existing `genomics/...Test.java`. Loads fixtures via
`getResourceAsStream("/ttio/fixtures/genomic/m86_codec_*.tio")`.
Place the fixture binaries under
`java/src/test/resources/ttio/fixtures/genomic/`.

Target ≥ 11 test methods, ≥ 30 assertions.

### 6.5 Cross-language conformance matrix

The three `.tio` fixtures committed in §6.2 are the cross-language
contract. Each implementation must read every fixture and produce
byte-identical decoded sequence/qualities data. The acceptance
section enumerates this explicitly.

---

## 7. Format-spec update

`docs/format-spec.md` already mentions per-channel attributes for
codec selection in §10.4 (numpress example). Add a new subsection
§10.5 (or extend §10.4) that documents the `@compression`
attribute scheme:

> ### 10.5 `@compression` attribute (M86)
>
> Signal-channel datasets that use a TTI-O internal compression
> codec (rANS order-0 / rANS order-1 / BASE_PACK) carry a
> `@compression` attribute (uint8) holding the M79 codec id. The
> dataset bytes ARE the self-contained codec stream specified in
> `docs/codecs/rans.md` (ids 4, 5) or `docs/codecs/base_pack.md`
> (id 6). No HDF5 filter is applied to such datasets — the codec
> output is high-entropy and would not benefit from deflate.
>
> Absence of the attribute, or value `0`, means the dataset is
> stored as-is and any HDF5 filter applies. Pre-M86 readers that
> ignore `@compression` will silently misinterpret a v0.12-encoded
> channel (the read path slices into a non-sliceable codec stream
> and returns garbage). The attribute is the canonical signal for
> codec dispatch.
>
> M86 wires this attribute scheme only for the `sequences` and
> `qualities` channels of `signal_channels/`. Integer channels
> (`positions`, `flags`, `mapping_qualities`) and VL_STRING
> channels (`cigars`, `read_names`) do not yet support TTIO
> codecs; they ignore `@compression` if set and stay on
> HDF5-filter ZLIB.

Also update §10.4's trailing summary paragraph: ids `4`, `5`, `6`
are now not just standalone primitives but **wired into the
genomic write/read pipeline** for the byte channels; the
`@compression` attribute is the dispatch mechanism.

---

## 8. Documentation

### 8.1 `docs/codecs/rans.md` and `docs/codecs/base_pack.md`

Each gains a brief "Wired into" sentence at the top of §7
("Forward references"):

> **M86** — wired into the genomic signal-channel write/read path
> for `sequences` and `qualities` channels. Use
> `WrittenGenomicRun.signal_codec_overrides={"sequences": ...}`
> at write time; reader dispatches on `@compression` automatically.

### 8.2 `CHANGELOG.md`

Add M86 entry under `[Unreleased]`. Mirror the M83/M84 structure
(Added — Verification — Notes). Update the Unreleased header to
include M86.

### 8.3 `WORKPLAN.md`

The "Genomic codec milestone" section currently flags rANS and
BASE_PACK as "implemented as standalone primitives, M86 wiring
pending." Update Phase 1 status: mark the wiring complete for
the byte channels; flag the integer-channel and VL_STRING codec
work as still pending.

---

## 9. Gotchas (continued from M84 §89–§95)

96. **Codec output isn't HDF5-sliceable.** The whole channel must
    be read and decoded in one shot. Any future code that adds
    streaming-decode support would require codec changes (out of
    M86 scope). The `_decoded_byte_channels` cache is the right
    shape for the current codecs.

97. **Don't double-compress.** When `@compression > 0`, the
    dataset must be created without an HDF5 filter
    (`compression=None` in the Python h5py call,
    `H5Pset_deflate` skipped in ObjC, no `setDeflate` in Java).
    Running deflate over rANS or BASE_PACK output adds CPU and
    typically *enlarges* the bytes (random-looking data
    compresses poorly).

98. **Per-channel attribute name is `compression`, not `codec`.**
    Single source of truth. The format-spec uses
    `@compression` everywhere; do not introduce variants like
    `@codec_id`, `@compression_codec`, etc. The attribute is on
    the dataset, not on the parent group.

99. **`WrittenGenomicRun.signal_compression` (string) and
    `signal_codec_overrides` (dict) are independent.** The string
    sets the default for channels NOT in the dict; the dict
    overrides per-channel. A run with `signal_compression="gzip"`
    and `signal_codec_overrides={"sequences": BASE_PACK}` writes
    sequences with BASE_PACK and qualities/positions/flags with
    gzip-via-HDF5. Cross-language tests must cover this hybrid
    case.

100. **Integer channels are deliberately out of scope.** Any
     attempt to override `positions`, `flags`, or
     `mapping_qualities` must raise. Test it explicitly. If a
     future milestone wants integer-channel codecs, it'll add an
     int↔byte serialisation contract — that contract doesn't
     exist yet, and silently accepting an integer-channel
     override would commit to one prematurely.

101. **Lazy decode is per-`GenomicRun`-instance, not global.**
     Two open `GenomicRun` objects on the same file each decode
     independently. This is correct (no shared mutable state)
     but means re-opening incurs the decode cost again. Document
     this in the `GenomicRun` class docstring.

102. **Compound channels (`cigars`, `read_names`, `mate_info`)
     ignore `@compression`.** They're not byte arrays, and their
     write/read goes through a different code path
     (`write_compound_dataset` / `read_compound_dataset`). Tests
     that check round-trip on those channels remain unchanged
     by M86.

---

## Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `881be0f`).
- [ ] `WrittenGenomicRun` has `signal_codec_overrides` field.
- [ ] Round-trip with each codec on `sequences` byte-exact (3 tests).
- [ ] Round-trip with RANS_ORDER1 on `qualities` byte-exact.
- [ ] Round-trip with mixed overrides byte-exact.
- [ ] Backwards-compat: empty overrides path unchanged.
- [ ] Override on integer channel raises ValueError at write time.
- [ ] Override with non-codec value raises ValueError at write time.
- [ ] `@compression` attribute is set correctly on the dataset.
- [ ] BASE_PACK on pure-ACGT sequences yields a dataset < 30% the
      size of the uncompressed equivalent.
- [ ] Three cross-language fixtures committed to
      `python/tests/fixtures/genomic/m86_codec_*.tio`.

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2047 PASS
      baseline + 2 pre-existing M38 Thermo failures).
- [ ] `TTIOWrittenGenomicRun.signalCodecOverrides` property added.
- [ ] All 11 round-trip tests pass byte-exact.
- [ ] Three cross-language fixtures (verbatim copies of Python's)
      placed under `objc/Tests/Fixtures/genomic/` and read
      byte-exact.
- [ ] ≥ 30 new assertions.
- [ ] Validation rejects invalid channel / invalid codec
      overrides cleanly (no crash).

### Java
- [ ] All existing tests pass (zero regressions vs 430/0/0/0 baseline → ≥ 441/0/0/0 after M86).
- [ ] `WrittenGenomicRun.signalCodecOverrides` setter/getter.
- [ ] All 11 round-trip tests pass byte-exact.
- [ ] Three cross-language fixtures (verbatim copies) under
      `java/src/test/resources/ttio/fixtures/genomic/` and read
      byte-exact.
- [ ] ≥ 11 test methods, ≥ 30 assertions.

### Cross-Language
- [ ] All three implementations read all three Python-generated
      fixtures with byte-identical decoded output.
- [ ] `docs/format-spec.md` §10.5 (or extended §10.4) committed
      describing the `@compression` attribute scheme.
- [ ] `docs/codecs/rans.md` and `docs/codecs/base_pack.md`
      updated with the M86 wiring sentence in §7.
- [ ] `CHANGELOG.md` M86 entry committed under `[Unreleased]`.
- [ ] `WORKPLAN.md` Phase 1 status updated to reflect wiring
      complete for byte channels.

---

## Out of Scope

- **Integer-channel codecs.** `positions`, `flags`,
  `mapping_qualities` continue to use HDF5 ZLIB. Adding TTIO
  codec support for these requires an int↔byte serialisation
  contract that's not defined here. Future milestone.
- **VL_STRING channel codecs.** `cigars`, `read_names`,
  `mate_info` continue to use the existing compound-write path.
  M85 (`name-tokenized`) is the natural follow-up.
- **MS-side wiring.** This milestone is genomic-only. The MS
  signal-channel path (`/study/ms_runs/.../signal_channels/`) is
  unchanged. If an MS use case for the new codecs arises later,
  it would be a sibling milestone with the same dispatch pattern
  but the MS storage shape (one channel per profile / centroid /
  noise / etc., float64 not uint8).
- **Streaming decode.** The lazy-decode-cache approach reads the
  whole channel into memory on first access. Future codecs (or
  future versions of rANS / BASE_PACK) that support block-level
  decode could enable streaming, but that's not in M86.
- **Changing the M83 / M84 codec wire formats.** Those are
  frozen across all three languages by their cross-language
  fixture conformance contracts; M86 just calls into them.
- **Performance optimisation.** The lazy-decode cost on first
  read is the natural overhead. SIMD, parallel decode of
  independent channels, etc. are out of scope.
