# TTI-O Workplan

Milestones with concrete deliverables and acceptance criteria.
Historical milestones (M1–M8) use the original MPEG-O class names
as a record of what was built; current milestones use TTI-O names.

---

## Phase 1 — Core Data Model (v0.1.0-alpha, complete)

### Milestone 1 — Foundation (Protocols + Value Classes) ✓
### Milestone 2 — SignalArray + HDF5 Wrapper ✓
### Milestone 3 — Spectrum + Concrete Spectrum Classes ✓
### Milestone 4 — AcquisitionRun + SpectrumIndex ✓
### Milestone 5 — SpectralDataset + Identification + Quantification + Provenance ✓
### Milestone 6 — MSImage (Spatial Extension) ✓
### Milestone 7 — Protection / Encryption ✓
### Milestone 8 — Query API + Streaming ✓

> All eight milestones shipped with v0.1.0-alpha. 379 tests on
> `ubuntu-latest`. See `docs/version-history.md` for per-milestone
> detail.

---

## Phase 2 — Cross-Language Parity + Production Features (v0.2–v1.0, complete)

### M9–M78 (v0.2.0 through v1.0.0) ✓

72+ milestones delivered across three languages (Objective-C, Python,
Java). Key capabilities shipped:

- Four storage/transport providers (HDF5, Memory, SQLite, Zarr v3)
- Seven importers, seven exporters
- .tis streaming transport protocol with WebSocket server/client
- Per-AU encryption (AES-256-GCM, ML-KEM-1024 key wrap, ML-DSA-87 signatures)
- Spectral anonymisation (proteomics, metabolomics, NMR)
- LZ4 + Numpress compression codecs
- MS2 activation/isolation data model (M74)
- ISA-Tab and ISA-JSON support
- Cross-language 3×3 conformance matrix

> See `CHANGELOG.md` for per-milestone detail. v1.0.0 tagged
> 2026-04-23.

---

## Phase 3 — TTI-O Rebrand + Genomic Foundation (v0.11, in progress)

### M79 — Modality Abstraction + Genomic Enumerations ✓

- `Precision.UINT8`, `Compression` values 4–8 (RANS_ORDER0 through
  NAME_TOKENIZED), `AcquisitionMode.GENOMIC_WGS/WES`, transport
  `spectrum_class=5`, `@modality` attribute, `opt_genomic` feature
  flag. All three languages.

### M80 — TTI-O Rebrand (Clean Sweep) ✓

- Repository-wide rename: MPEG-O → TTI-O, MPGO → TTIO, `.mpgo` →
  `.tio`, `.mots` → `.tis`, transport magic `"MO"` → `"TI"`. No
  backward compatibility.

### M81 — Java Reverse-DNS Correction ✓

- `com.dtwthalion.ttio` → `global.thalion.ttio`. Maven groupId
  corrected to `global.thalion`.

### M82 — GenomicRun + AlignedRead + Signal Channel Layout ✓

Shipped as five sub-milestones (M82.1–M82.5):

- M82.1: Python reference — `AlignedRead`, `GenomicIndex`,
  `GenomicRun`, `WrittenGenomicRun`. `/study/genomic_runs/` group
  with signal channels + genomic index. `SpectralDataset` extended.
- M82.2: ObjC normative — `TTIOAlignedRead`, `TTIOGenomicRun`,
  `TTIOGenomicIndex`, `TTIOWrittenGenomicRun`.
- M82.3: Java — `AlignedRead` record, `GenomicRun`, `GenomicIndex`,
  `WrittenGenomicRun`. `Precision.UINT64` added.
- M82.4: Cross-language wire parity — Java VL_STRING-in-compound
  fix. Full 3×3 conformance matrix. `TtioWriteGenomicFixture` +
  `TtioVerify` genomic extensions.
- M82.5: Documentation — `docs/M82.md`, `ARCHITECTURE.md` genomic
  section, format-spec §10 codec gap correction.

> Python 854 tests, ObjC 1935 assertions, Java 402 tests. Genomic
> data stored with zlib compression; CRAM-derived codecs ship in
> M83–M86.

---

## Phase 4 — Genomic Compression Codecs (v0.11, in progress)

**Architectural premise:** All compression codecs are clean-room
implementations from published academic literature. No htslib source
code is consulted. htslib (via samtools) is used only as a runtime
bridge for BAM/CRAM file import and export. Sources: rANS from Duda
2014 (public domain); base packing from standard 2-bit nucleotide
encoding; quality quantisation from published Illumina binning tables;
name tokenisation from Bonfield, Bioinformatics 2022.

### M83 — rANS Entropy Codec + MPGO Remnant Cleanup (in progress)

- Clean-room rANS order-0 and order-1 encoder/decoder across all
  three languages.
- Self-contained wire format (header + frequency table + payload).
- Canonical test vectors with cross-language byte-exact conformance.
- `MPGOInstrumentConfig.h` renamed to `TTIOInstrumentConfig.h`;
  zero MPGO references remaining in ObjC source.

### M84 — Base-Packing + Quality Quantiser Codecs

- `ttio.codecs.base_pack`: 2-bit ACGT packing (4 bases per byte),
  N positions in side-channel. 4:1 raw compression before entropy
  coding.
- `ttio.codecs.quality`: Phred score quantisation with schemes
  `"illumina-8"` (8 bins), `"crumble-40"` (near-lossless),
  `"lossless"` (passthrough). Per-run configurable.
- All three languages. Cross-language byte-exact conformance.

### M85 — Quality Quantiser + Name Tokeniser Codecs

**Status: Phase A and Phase B both shipped (2026-04-26).**

The original M84 sketch in this WORKPLAN bundled "Base-Packing +
Quality Quantiser Codecs"; the M84 milestone shipped only
BASE_PACK on 2026-04-26, and quality_binned slipped to M85. M85
is now restructured into two phases: Phase A is the catch-up
quality codec, Phase B is the original name_tokenizer scope.

#### Phase A — quality_binned codec (SHIPPED 2026-04-26)

- [x] `ttio.codecs.quality` — fixed Illumina-8 / CRUMBLE-derived
      8-bin Phred quantisation table, 4-bit-packed bin indices,
      big-endian within byte. Lossy by construction;
      `decode(encode(x)) == bin_centre[bin_of[x]]`.
- [x] All three languages, cross-language byte-exact fixtures
      (`quality_{a,b,c,d}.bin`).
- [x] Phred 41+ saturates to bin 7 / centre 40 (documented).
- [x] Wire format: `[1 B version=0x00][1 B scheme_id=0x00][4 B
      BE orig_len][packed body of ceil(orig/2) bytes]`.
- [x] M79 codec id `7` slot now has a working encoder + decoder.
- [x] `docs/codecs/quality.md` codec spec.
- [x] `docs/format-spec.md` §10.4 quality-binned row flipped.

Commits: `9cfb08b` (Python), `5ad8952` (Java), `1449502` (ObjC),
plus M85 Phase A docs landing alongside.

Throughput on the M85 Phase A reference host (4 MiB random Phred
mod 41): Python 61 / 471 MB/s, Java 2001 / 425 MB/s, ObjC 3203 /
2196 MB/s.

#### Phase B — name_tokenizer codec (SHIPPED 2026-04-26)

- [x] `ttio.codecs.name_tokenizer` — lean two-token-type
      columnar codec (numeric digit-runs without leading zeros +
      string non-digit-runs absorbing leading-zero digit-runs),
      per-column type detection (columnar mode vs verbatim
      fallback), delta-encoded numeric columns,
      inline-dictionary-encoded string columns.
- [x] All three languages, cross-language byte-exact fixtures
      (`name_tok_{a,b,c,d}.bin`).
- [x] M79 codec id `8` slot now has a working encoder + decoder.
- [x] `docs/codecs/name_tokenizer.md` codec spec.
- [x] `docs/format-spec.md` §10.4 name-tokenized row flipped.
- Compression target was originally ≥ 20:1 (CRAM 3.1 / Bonfield
  2022 style); Phase B's lean implementation achieves ~3–7:1.
  Reaching 20:1 requires the full Bonfield-style encoder (eight
  token types — DIGIT0, MATCH, DUP, ALPHA-vs-CHAR distinction,
  per-token-type encoding variants — multi-thousand lines per
  language with substantial cross-language byte-exact
  conformance work). Tracked as a future optimisation milestone.

Commits: `cf665e7` (Python), `6a7e22a` (Java), `a66e750` (ObjC),
plus M85 Phase B docs landing alongside.

Throughput on the M85 Phase B reference host (100k Illumina-style
names, 2.18 MB raw): Python 5.4 / 16.5 MB/s, Java ~14 / ~63
MB/s, ObjC 37.0 / 310.7 MB/s.

#### Forward reference

A future M86 phase will wire QUALITY_BINNED (id 7) into the
`qualities` channel and NAME_TOKENIZED (id 8) into the
`read_names` channel of `signal_channels/`. The wiring
infrastructure (per-channel `signal_codec_overrides` dict,
`@compression` attribute, lazy-decode cache) is already in
place from M86 Phase A for byte channels; the `read_names`
channel will additionally need lifting from VL_STRING-in-
compound storage to a flat dataset that can carry the
`@compression` attribute.

#### Codec stack status (post-M85 Phase B)

All five M79 codec slots (4–8) now have working encoders +
decoders across Python, ObjC, and Java with cross-language
byte-exact conformance fixtures. The genomic codec library is
conceptually complete; remaining work is pipeline-wiring
(future M86 phases) and optional optimisation milestones for
higher compression ratios.

### M86 — Codec Integration into Signal Channel Pipeline

**Status: Phases A, B, D, and E shipped (2026-04-26). Phase C deferred.**

#### Phase A — byte channels (SHIPPED 2026-04-26)

- [x] Wire rANS order-0/1 and BASE_PACK into the genomic signal
      channel write/read paths for the **byte channels only** —
      `sequences` and `qualities`.
- [x] `@compression` attribute on coded channels (uint8 holding
      the M79 codec id; provider-agnostic data transform, not
      HDF5 filter; lives on the dataset, not the parent group).
      Note: original WORKPLAN sketched `@_ttio_codec`; final
      shipped name is `@compression` to match the format-spec
      convention.
- [x] `WrittenGenomicRun.signal_codec_overrides` (per-channel
      opt-in dict) on Python, ObjC, Java.
- [x] Validation rejects overrides for non-byte channels and
      non-codec values (sequences/qualities + RANS_ORDER0/1 +
      BASE_PACK only).
- [x] Codec-compressed datasets carry no HDF5 filter (no
      double-compression).
- [x] Lazy whole-channel decode + per-instance cache on the open
      `GenomicRun` object.
- [x] All three languages + cross-language `.tio` fixture
      conformance: 3 fixtures (one per codec) generated by
      Python; ObjC and Java each read all three byte-exact.
- [x] BASE_PACK on pure-ACGT sequences hits ~19% of uncompressed
      size (target was < 30%).

Commits: `31b0fa48` (Python), `0450913` (Java), `d2befc20` (ObjC),
plus M86 docs landing alongside.

#### Phase D — QUALITY_BINNED wiring (SHIPPED 2026-04-26)

- [x] Extend the M86 Phase A dispatch to accept
      `Compression.QUALITY_BINNED` (M79 codec id `7`) on the
      qualities byte channel of genomic runs.
- [x] Per-channel allowed-codec map: sequences accepts
      RANS_ORDER0/1 + BASE_PACK; qualities accepts those plus
      QUALITY_BINNED. Validation rejects `(sequences,
      QUALITY_BINNED)` with a clear lossy-quantisation error
      message (Binding Decision §108) — applying Phred-bin
      quantisation to ACGT bytes would silently destroy the
      sequence data.
- [x] Reuses M85 Phase A `Quality.encode/decode` codec and the
      M86 Phase A wiring infrastructure (per-channel
      `signal_codec_overrides` dict, `@compression` attribute,
      lazy-decode cache); zero new infrastructure.
- [x] All three languages, cross-language `.tio` fixture
      conformance: 1 new fixture
      (`m86_codec_quality_binned.tio`, 48 432 bytes) generated
      by Python; ObjC and Java both read it byte-exact (BASE_PACK
      on sequences + QUALITY_BINNED on qualities, bin-centre
      values for byte-exact lossy round-trip).
- [x] QUALITY_BINNED on a 100k-byte qualities channel hits ~50%
      of the HDF5-chunked-ZLIB baseline.

Commits: `425393a` (Python), `5d09294` (Java), `e7a85c6` (ObjC),
plus M86 Phase D docs landing alongside.

#### Phase B — integer channels (SHIPPED 2026-04-26)

- [x] Wire `RANS_ORDER0` and `RANS_ORDER1` (M79 codec ids 4 + 5)
      into the three integer channels of `signal_channels/`:
      `positions` (int64), `flags` (uint32),
      `mapping_qualities` (uint8).
- [x] Defines the int↔byte serialisation contract: integer
      arrays serialise to **little-endian** bytes per element
      before encoding; reader looks up original dtype by
      channel name (no on-disk dtype attribute, per Binding
      Decision §115).
- [x] Per-channel allowed-codec map gains positions/flags/
      mapping_qualities entries (rANS only). Validation
      rejects BASE_PACK / QUALITY_BINNED / NAME_TOKENIZED on
      integer channels (wrong-content codecs) per §117.
- [x] New per-instance `_decoded_int_channels` cache (separate
      from byte-channel and read-names caches per Binding
      Decision §116).
- [x] All three languages, cross-language `.tio` fixture
      conformance: 1 new fixture
      (`m86_codec_integer_channels.tio`, 60 720 bytes) with
      all three integer channels under rANS — Python, ObjC,
      Java all decode byte-exact.
- [x] Compression on clustered-positions int64 (10000-read /
      100-locus pattern): ~18% of raw LE bytes, byte-identical
      across all three languages (M83 rANS conformance).

**Important caveat (Binding Decision §119):** The current M82
read path for per-read integer fields uses `genomic_index/`,
not `signal_channels/`. Phase B compression is therefore
primarily a **write-side file-size optimisation**; it does not
currently affect read performance through `__getitem__` /
`alignedReadAt(int)`. The new `_int_channel_array(name)`
helper IS callable for direct access; future readers that
prefer `signal_channels/` (streaming, M89 transport) will
benefit transparently.

Commits: `798ec88` (Python), `46076b1` (Java), `6213711`
(ObjC), plus M86 Phase B docs landing alongside.

#### Phase C — VL_STRING / compound channels (DEFERRED)

`cigars` and `mate_info` continue to use the existing
compound-write path. `cigars` would want an RLE-then-rANS
pipeline; `mate_info` lacks an obvious codec match.

#### Phase E — NAME_TOKENIZED wiring + read_names schema lift (SHIPPED 2026-04-26)

- [x] When `signal_codec_overrides["read_names"]` is set, the
      writer replaces the M82 compound `read_names` dataset
      with a flat 1-D uint8 dataset of the same name containing
      the codec output, and sets `@compression == 8` on it.
- [x] The reader dispatches on dataset shape (compound → M82
      path; 1-D uint8 → codec dispatch via the lazy-decode
      list cache).
- [x] Per-channel allowed-codec map gains `read_names:
      {NAME_TOKENIZED}`. NAME_TOKENIZED is rejected on
      `sequences` and `qualities` (would mis-tokenise binary
      byte streams) per Binding Decision §113.
- [x] New per-instance cache `_decoded_read_names: list[str]`
      separate from the byte-channel cache per Binding
      Decision §114.
- [x] All three languages, cross-language `.tio` fixture
      conformance: 1 new fixture (`m86_codec_name_tokenized.tio`,
      48 432 bytes) generated by Python; ObjC and Java both
      read it byte-exact.
- [x] All read-side call sites audited (only `__getitem__`
      directly touches `read_names`; region queries inherit
      via `self[i]`).
- [x] Compression on 1000 structured Illumina names: ~50%
      (Python/Java via H5 storage-size baseline) to ~19%
      (ObjC via file-size delta baseline; both methodologies
      undercount differently due to VL_STRING heap accounting).

Commits: `d12d135` (Python), `6624406` (Java), `bc6158c`
(ObjC), plus M86 Phase E docs landing alongside.

The schema-lift pattern is documented in `docs/format-spec.md`
§10.6 alongside the M86 Phase A `@compression` attribute scheme
in §10.5.

#### Codec stack pipeline-wiring status (post-M86 Phase E)

All five M79 codec slots (4–8) are now wired into the genomic
signal-channel pipeline. The genomic codec stack is conceptually
complete for the byte and string channels; remaining work
(integer channels — Phase B; cigars/mate_info — Phase C) is
deferred future scope.

#### Original wishlist preserved for future scope

- Default pipeline: positions → delta + rANS order-1; sequences →
  base_pack + rANS order-0; qualities → quality_quantise + rANS
  order-0; flags → rANS order-0; read_names → name_tokenizer;
  cigars → RLE + rANS order-0.
- Compression ratio benchmarking vs. uncompressed (target ≥ 5:1).

---

## Phase 5 — Import/Export + Interoperability

### M87 — SAM/BAM Importer

- `ttio.importers.bam`: reads BAM via `samtools view` subprocess.
  `BamReader.to_genomic_run()` with optional region filter.
- SAM header parsing: @SQ → reference_uri, @RG → read group metadata,
  @PG → provenance chain.
- `ttio.importers.sam`: thin wrapper (SAM → BAM → BamReader).
- All three languages.

### M88 — CRAM Importer + BAM/CRAM Exporter

- `ttio.importers.cram`: reads CRAM via `samtools view -h` + reference
  FASTA.
- `ttio.exporters.bam`: GenomicRun → SAM text → `samtools view -b`.
- `ttio.exporters.cram`: GenomicRun → SAM text → `samtools view -C`.
- Lossless round-trip: BAM → .tio → BAM, field-by-field comparison.
- Lossy round-trip: quality binning tolerance documented.
- All three languages.

---

## Phase 6 — Framework Integration

### M89 — Transport Layer Extension

- `.tis` GenomicRead AU payload: chromosome + position + mapq + flags
  prefix (replaces zeroed spectral fields from M79).
- `TransportWriter.write_genomic_run()` / `TransportReader`
  materialisation.
- `AUFilter` extended with chromosome + position_range predicates.
- Multiplexed streams: MS + genomic runs interleaved in one `.tis`.
- Per-AU encryption on genomic AUs verified end-to-end.
- All three languages + 3×3 cross-language transport matrix.

### M90 — Encryption, Signatures, and Anonymisation for Genomic Data

- Per-AU encrypt/decrypt verified on genomic signal channels.
- PQC signatures (ML-DSA-87) on genomic datasets.
- Genomic anonymisation: strip read names, randomise quality scores,
  optionally mask specific regions (e.g., HLA loci).
- Region-based encryption: encrypt chr6 (HLA), leave chr1 in clear.
- Cross-language encrypt/verify matrix.

### M91 — Multi-Omics Integration Test

- Single `.tio` containing: WGS genomic run (10K reads) + proteomics
  MS run (1K spectra) + NMR metabolomics run (100 spectra).
- Shared provenance linking all three to a common sample.
- Unified encryption envelope.
- Cross-modality query ("all data from sample NA12878").
- `.tis` transport: stream the multi-omics file, all three runs
  materialise correctly.
- All three languages.

---

## Phase 7 — Release

### M92 — Benchmarking, Documentation, and v0.11.0 Tag

- Compression benchmarking report: TTI-O genomic vs. BAM, CRAM 3.1,
  and MPEG-G (Genie) on NA12878 WGS (downsampled), ERR194147 WES,
  and a synthetic mixed-chromosome dataset.
- Documentation refresh: README, ARCHITECTURE, migration guide.
- v0.11.0 CHANGELOG entry.
- Tag gated on user sign-off.

**Acceptance Criteria**

- [ ] Compression within 15% of CRAM 3.1 on all benchmarks (lossless).
- [ ] All three language test suites pass.
- [ ] Cross-language 3×3 conformance matrix green for .tio + .tis
      with genomic data.
- [ ] Multi-omics integration test (M91) green.

---

## Binding Decisions (Genomic Integration)

| # | Decision | Rationale |
|---|---|---|
| 60 | `modality` is a UTF-8 string attribute, not an enum integer. | Extensible for future modalities without enum-value coordination. |
| 61 | Codecs are provider-agnostic data transforms with `@_ttio_codec` attribute, not HDF5 filter plugins. | Works identically on Memory, SQLite, Zarr, and HDF5. HDF5 filter registration deferred to v1.1+. |
| 62 | Base-packing uses 2-bit big-endian within each byte (MSB-first). N positions in separate side-channel. | Bit-compatible with CRAM convention; simplifies cross-validation. |
| 63 | Quality quantisation scheme is a per-run attribute (`@quality_quantisation`). | Different runs in the same file may use different quantisation. |
| 64 | `samtools` is a runtime dependency only for BAM/CRAM import/export. TTI-O's compression pipeline has zero htslib dependency. | htslib's value is as a BAM/CRAM format parser, not as a compression library. |
| 65 | GenomicRead AU payload uses a genomic-specific prefix (chromosome + position + mapq + flags). | Genomic filter keys are fundamentally different from spectral filter keys. |
| 66 | All compression codecs are clean-room implementations from published literature. No htslib source consulted. | Independence and credibility: TTI-O's pipeline is an original implementation of public-domain algorithms. |
| 67 | No backward compatibility with `.mpgo` / `mpeg_o_*` attributes. Clean break. | No external users. Dual-read logic adds complexity with zero benefit. |
| 68 | Transport magic: `"TI"` (Thalion Initiative). | Two-byte mnemonic, no known collision. |
| 69 | `"MPAD"` debug dump magic not renamed. | Internal diagnostic format, not public wire spec. |
| 70 | Genomic runs under `/study/genomic_runs/`, separate from ms_runs. | Clean dispatch; ms_runs iterators never see genomic groups. |
| 71 | M82 stores one ASCII byte per base. Base-packing deferred to codec milestone. | Separation of concerns: validate data model first. |
| 72 | Flags stored as UINT32 (not UINT16). | Future-proofing for extended flag bits. |
| 73 | GenomicIndex.chromosomes is `list[str]`, stored as compound VL_BYTES. | Variable-length strings; established pattern. |
| 74 | Data model classes ship in all three languages in the same milestone. | Language parity is a core principle. |
| 75 | rANS state: 64-bit, L=2^23, b=2^8. | Standard Duda 2014 parameterisation. |
| 76 | Frequency table normalisation total M=4096. | Power-of-two for fast modulo. |
| 77 | Wire format: big-endian, self-contained header. | Embeddable in HDF5 datasets or .tis packets without external metadata. |
| 78 | Frequency rounding: descending count, stable by symbol value. | Deterministic cross-language byte-exact conformance. |
| 79 | MPGO remnant cleanup mandatory in M83. | Zero tolerance for stale pre-rebrand identifiers. |

---

## Deferred to v1.1+

| Item | Description |
|---|---|
| HDF5 filter registration | Register rANS/base_pack/quality/name_tokenizer as official HDF5 filter IDs with The HDF Group. |
| Population-level deduplication | Cross-sample content-defined chunking and dedup at the genomic region level. |
| Long-read support | PacBio HiFi / Oxford Nanopore: longer sequences, higher error rates, different codec tuning. |
| VCF/gVCF importer | Import variant call files as VariantAnnotation records. |
| htsget-style REST API | HTTP range-request protocol for serving genomic regions from .tio files. |
| Methylation / epigenomics | Extended base alphabet (5mC, 5hmC) and modified-base probability arrays. |
| CRAM native interop | Direct htslib linking for high-throughput BAM/CRAM conversion (bypass samtools subprocess). |
| Transcriptomics modality | RNA-seq: splice-junction awareness, expression quantification, gene-level aggregation. |
| ParquetProvider | Apache Parquet as a fifth storage provider. |
| FIPS compliance mode | FIPS 140-3 validated crypto backend. |
| DBMS transport | Database-backed streaming for enterprise deployments. |
| rANS-Nx16 / fqzcomp | CRAM 3.1 advanced codecs (interleaved 4-way rANS, quality-score-specific compressor). Performance optimisation over basic rANS order-0/1. |
| M40 PyPI + Maven Central publishing | Package registry publication (internal-only until further notice). |
