# Cross-Language Conformance Matrix

> **Status:** Draft, hand-curated 2026-04-26 against `main` @ `a53d0e2`.
> Companion to `docs/verification-workplan.md` §V3. Rebuild whenever a new
> milestone adds (or removes) a cross-language harness.

This document inventories every cross-language conformance harness in the
repo, names the CLI tools and fixtures each harness consumes, and surfaces
the features that have **no** cross-language verification today. It is the
single source of truth a maintainer should consult before claiming
"feature X is verified in all three languages."

---

## 1. Conformance contract definitions

Cross-language coverage is graded on a four-level ladder:

| Level | Symbol | Meaning |
|---|---|---|
| **byte-exact** | `=` | The output bytes (canonical JSON, encrypted ciphertext, `.tio` chunk, signature blob, codec output) are bit-identical between languages. The strongest contract; every byte of the wire format is pinned. |
| **field-equal** | `~` | Parsed object equality: `dsA.spectrum.intensity == dsB.spectrum.intensity` field-for-field, with appropriate numeric tolerance (typically `rtol=1e-9, atol=1e-12` for float64). Used where the on-disk encoding intentionally allows variation (e.g., HDF5 chunk layout) but the API-visible content must agree. |
| **smoke** | `S` | Subprocess runs without crash/exit-non-zero; the JSON / output may be inspected for shape but not for value parity. |
| **none** | `—` | No cross-language harness exists; only per-language unit tests. |

Where a harness gates one direction (e.g., Python writes, Java reads) but
not the inverse, the cell is annotated `=>` or `<=` to call out the
asymmetry.

Cells in the 3-way column require *all three* pairwise relations to
hold at the named level for that cell.

---

## 2. Coverage matrix

Rows are features (one per milestone or feature group); cells are
contract levels per language pair. Footnotes follow the table.

| Feature / milestone | Python ↔ ObjC | Python ↔ Java | ObjC ↔ Java | 3-way | Harness |
|---|---|---|---|---|---|
| **M18** v2 HMAC dataset signature | `=` (1) | — (2) | — (2) | — | `python/tests/test_canonical_signatures.py` |
| **M21 / M51** compound-dataset canonical JSON dump | `=` | `=` | `=` | `=` | `python/tests/test_compound_writer_parity.py` |
| **M24** chromatograms in `.tio` | `S` (3) | — | — | — | `python/tests/test_milestone24_chromatograms.py` |
| **M25 / M47** key-rotation envelope (wrapped DEK) | `S` (4) | — | — | — | `python/tests/test_milestone25_key_rotation.py` |
| **M43** `readCanonicalBytes()` cross-backend (provider parity, *not* cross-lang) | n/a | n/a | n/a | n/a | `objc/Tests/TestCanonicalBytesCrossBackend.m`, Java `CanonicalBytesCrossBackendTest.java` |
| **M45** N-D dataset cross-backend (provider parity, *not* cross-lang) | n/a | n/a | n/a | n/a | `objc/Tests/TestNdDatasetCrossBackend.m`, Java `NdDatasetCrossBackendTest.java` |
| **M54** PQC ML-DSA-87 sign / verify (primitive) | `S` (5) | `S` (5) | `S` (5) | `S` | `python/tests/test_m54_pqc_conformance.py` |
| **M54** PQC ML-KEM-1024 encaps / decaps | `=` (6) | `=` (6) | `=` (6) | `=` | `python/tests/test_m54_pqc_conformance.py` |
| **M54** v3 ML-DSA HDF5 dataset signature | `S` (5) | `S` (5) | `S` (5) | `S` | `python/tests/test_m54_pqc_conformance.py` |
| **M54.1** v3 sig on Zarr / SQLite providers | `S` (5) | `S` (5) | `S` (5) | `S` | `python/tests/test_m54_1_provider_pqc.py` |
| **M62-x / M64.5** MS-only `.tio` summary (HDF5 provider) | `~` | `~` | `~` (7) | `~` | `python/tests/validation/test_cross_language_smoke.py` |
| **M64.5** 4-provider matrix (HDF5/Memory/SQLite/Zarr) | `~` HDF5 + SQLite + Zarr (10) | `~` HDF5 + SQLite + Zarr (8) | — | — | same |
| **M64** mzML / nmrML / ISA-Tab against external validators | n/a (9) | n/a (9) | n/a (9) | n/a | `python/tests/validation/test_m64_cross_tool_validation.py` |
| **M67** transport codec (`.tis`) round-trip | `=` (11) | `=` (11) | — | — | `python/tests/test_transport_conformance.py` |
| **M73** Raman / IR JCAMP-DX writer + reader | `=` writer-bytes; `~` Py→ObjC parsed | `~` Py→Java parsed | — | — | `python/tests/integration/test_raman_ir_cross_language.py` |
| **M75** CLI surface parity (`ttio-sign`, `ttio-verify`, `ttio-pqc`) | `S` (12) | `S` (12) | `S` (12) | `S` | `python/tests/test_m75_cli_parity.py` (Python side) |
| **M76** JCAMP-DX compressed writer (PAC / SQZ / DIF goldens) | `=` (13) | `=` (13) | `=` (13) | `=` | `python/tests/test_m76_jcamp_conformance.py` (+ Java/ObjC golden parity) |
| **M77** 2D-COS sync / async matrices | `~` (14) | `~` (14) | `~` (14) | `~` | `python/tests/test_m77_two_d_cos_conformance.py` (+ Java/ObjC sibling) |
| **M78** mzTab feature / identification parsing | `~` (15) | `~` (15) | `~` (15) | `~` | `python/tests/test_m78_mztab_conformance.py` (+ Java/ObjC sibling) |
| **M82** GenomicRun 3×3 writer × reader matrix | `=`+`~` (16) | `=`+`~` (16) | `~` | `~` | `python/tests/validation/test_m82_3x3_matrix.py` |
| **M83** rANS order-0 / order-1 codec | `=` (17) | `=` (17) | `=` (17) | `=` | `python/tests/test_m83_rans.py` (Python golden producer; ObjC/Java goldens consumed by their own tests) |
| **M84** BASE_PACK genomic-sequence codec | `=` (17) | `=` (17) | `=` (17) | `=` | `python/tests/test_m84_base_pack.py` |
| **M85a** QUALITY_BINNED codec | `=` (17) | `=` (17) | `=` (17) | `=` | `python/tests/test_m85_quality.py` |
| **M85b** NAME_TOKENIZED codec | `=` (17) | `=` (17) | `=` (17) | `=` | `python/tests/test_m85b_name_tokenizer.py` |
| **M86** genomic codec wiring (`.tio` byte-exact across 8 fixtures) | `=` (18) | `=` (18) | `=` (18) | `=` | `python/tests/test_m86_genomic_codec_wiring.py` (+ Java `M86CodecWiringTest`, ObjC `TestM86GenomicCodecWiring`) |
| **M87** SAM/BAM importer canonical JSON | `=` | `=` | `=` (19) | `=` | `python/tests/integration/test_m87_cross_language.py` |
| **M88** BAM round-trip + 5-read fixture canonical JSON | `=` | `=` | `=` (19) | `=` | `python/tests/integration/test_m88_cross_language.py` |
| **M88.1** CRAM via `bam_dump --reference` | `=` | `=` | `=` (19) | `=` | `python/tests/integration/test_m88_cross_language.py` |
| **v1.0 per-AU encryption** (`.mpad` decrypt parity) | `=` (20) | `=` (20) | `=` (20) | `=` | `python/tests/integration/test_per_au_cross_language.py` |
| **v1.0 per-AU transport** (`.tis` send/recv) | `=` (20) | `=` (20) | `=` (20) | `=` | `python/tests/integration/test_per_au_cross_language.py` |
| **M51** Numpress codec (delta + slof) cross-lang structural | `S` (21) | — | — | — | `python/tests/test_compression_codecs.py` |
| **MS-fixture archive backward-compat** (5 ObjC-built `.tio` fixtures) | `~` (22) | — | — | — | `python/tests/test_cross_compat.py`, `python/tests/validation/test_m64_cross_tool_validation.py` |

### Footnotes

1. **M18:** `test_objc_signed_file_verifies_from_python` calls a real
   `TtioSign` ObjC binary on a Python-written `.tio`; Python verifies the
   resulting `v2:` signature byte-for-byte. The reverse direction
   (`test_python_signed_file_verifies_from_objc`) is documented as a
   placeholder (no `--verify-signature` flag in `TtioVerify` yet).
2. **M18 Java side:** No cross-language signature harness exists for Java.
   Java's `ProtectionTest` covers same-process round-trip only.
3. **M24 chromatograms:** Cross-lang test is gated on the ObjC writer
   producing a chromatogram fixture and is currently a guard-rail
   skipped when no ObjC fixture is found. No Java cross-lang harness.
4. **M25 key rotation:** The "cross-language parity" test is intentionally
   structural — it rebuilds the wrapped-key blob and verifies its byte
   layout in-process. The actual end-to-end ObjC↔Python file exchange is
   covered only on the ObjC side (`TestMilestone25.m`).
5. **M54 PQC sign / HDF5-v3:** ML-DSA signatures are randomised, so the
   contract is "verifier returns 0", not "bytes equal". Smoke (`S`) is
   the strongest level the contract permits.
6. **M54 ML-KEM:** The shared-secret bytes are byte-compared after
   encaps in language A → decaps in language B. This is byte-exact on
   the *recovered secret*, even though the ciphertext itself is random.
7. **M62-x ObjC↔Java:** Both readers parse the same Python-written
   `.tio`; the test asserts each summary == `_python_summary(...)`,
   which transitively pins ObjC↔Java equality (both equal Python).
   No direct ObjC-vs-Java assert.
8. **M64.5 Python↔Java 4-provider:** SQLite + Zarr cross-language reads
   pass after v0.9 fixes; `memory://` is xfail by design (in-process only).
   ObjC reads HDF5 + SQLite + Zarr via `readViaProviderURL` (Memory rejects).
9. **M64 cross-tool validation:** Validates Python exporter against
   *external* validators (lxml + PSI XSDs, pyteomics, pymzml, isatools).
   Not a Python↔ObjC↔Java check; included here because it's the closest
   thing to "third-party reads our wire format."
10. **M64.5 Python↔ObjC 4-provider:** Same shape as note 8;
    `test_objc_reads_python_non_hdf5` covers SQLite + Zarr explicitly.
11. **M67 transport:** `_assert_signal_equal` in
    `test_transport_conformance.py` does field-equal on signal arrays
    (rtol-bounded), and the `.tis` stream itself is byte-stable enough
    that pipe-through-and-decode round-trips. ObjC↔Java not tested
    directly (Python is always the pivot).
12. **M75 CLI parity:** Python-side test asserts entry-point declaration
    + functional round-trip. The Java/ObjC equivalents (`TtioVerify`,
    `PQCTool`, `TtioSign`) are covered structurally by the M18 / M54
    harnesses; the M75 file itself does not subprocess into them.
13. **M76:** The PAC/SQZ/DIF goldens under `conformance/jcamp_dx/` are
    the cross-language byte-parity contract. Each language regenerates
    the same byte-for-byte output and asserts equality with the golden.
    Java's `JcampDxM76ConformanceTest` and ObjC's `TestM76JcampConformance`
    are the sibling halves.
14. **M77 2D-COS:** Each language reads `conformance/two_d_cos/sync.csv`
    + `async.csv` and asserts allclose. Field-equal because the matrix
    values are float-tolerant; the contract is float64 within `rtol=1e-9`.
    (Java `TwoDCosTest` and ObjC `TestM77` ship the sibling halves.)
15. **M78 mzTab:** Each language reads
    `conformance/mztab_features/{proteomics,metabolomics}.mztab` and
    asserts the same parsed feature counts + sequences + charges +
    confidence scores. Java `MzTabReaderM78ConformanceTest` is the
    sibling.
16. **M82 GenomicRun 3×3:** The matrix asserts
    *summary* equality (read_count, sample_name, etc.) for all 9 cells —
    that's a `~` field-equal contract. Additionally,
    `test_m82_field_level_python_reads_objc_and_java` does field-equal
    on the per-read level (read_name, cigar, chromosome, sequence
    bytes). The HDF5 file bytes themselves are NOT byte-equal across
    writers (HDF5 chunk layout depends on writer); only the M86 codec
    fixtures (next row) achieve byte-exact `.tio`s.
17. **M83/M84/M85a/M85b codecs:** Cross-language byte-exactness is
    enforced via the canonical fixtures in
    `python/tests/fixtures/codecs/{rans,base_pack,quality,name_tok}_*.bin`.
    Each language's port reads the Python-produced fixture and asserts
    encode(input) == fixture_bytes and decode(fixture_bytes) == input.
18. **M86:** Eight `.tio` fixtures committed under
    `python/tests/fixtures/genomic/m86_codec_*.tio` are byte-exact across
    all three languages. Each language regenerates and asserts identity.
    This is the strongest cross-language contract in the repo (entire
    HDF5 file is bit-identical).
19. **M87/M88 ObjC↔Java:** The Python harness asserts both `objc == python`
    and `java == python`, which transitively pins ObjC == Java.
20. **v1.0 per-AU:** `RUNNERS` builds the cartesian product
    `{py, objc, java} × {py, objc, java}` and asserts byte-equal `.mpad`
    decrypt output for every (encrypt-lang, decrypt-lang) pair × headers
    × no-headers — typically 18+ cells when all three CLIs are built.
    Same for the transport `.tis` send/recv pairs.
21. **Numpress:** Python writes a Numpress-compressed `.tio` and asserts
    ObjC `TtioVerify` reads back the same run + spectrum counts. Does
    NOT byte-compare the Numpress payload itself; that's covered
    indirectly by the formula-equality check
    (`test_numpress_scale_matches_objc_formula`).
22. **MS-fixture archive:** Five canonical `.tio` fixtures under
    `objc/Tests/Fixtures/ttio/` (minimal_ms / full_ms / nmr_1d /
    encrypted / signed) are written by the ObjC build at each
    milestone and Python is contractually required to read every one.
    No Java equivalent today — Java does not ingest the ObjC archive.

---

## 3. CLI inventory

The harnesses depend on per-language CLI tools. Build them via:

* Python: `pip install -e python[test]` (entry points declared in
  `python/pyproject.toml` `[project.scripts]`).
* ObjC: `cd objc && ./build.sh` (binaries land in `objc/Tools/obj/`).
* Java: `cd java && mvn compile dependency:build-classpath -DincludeScope=test -Dmdep.outputFile=target/_smoke_cp.txt`
  (mains live in `java/src/main/java/global/thalion/ttio/{tools,importers}/`).

| Purpose | Python | ObjC | Java |
|---|---|---|---|
| BAM/CRAM dump (canonical JSON) | `python -m ttio.importers.bam_dump` | `objc/Tools/obj/TtioBamDump` | `global.thalion.ttio.importers.BamDump` |
| Per-AU encrypt/decrypt/transcode/send/recv | `python -m ttio.tools.per_au_cli` | `objc/Tools/obj/TtioPerAU` | `global.thalion.ttio.tools.PerAUCli` |
| `.tio` summary (cross-lang verify pivot) | `python -m ttio.tools.ttio_verify_cli` (`ttio-verify`) | `objc/Tools/obj/TtioVerify` | `global.thalion.ttio.tools.TtioVerify` |
| Sign a dataset (M18) | `ttio-sign` | `objc/Tools/obj/TtioSign` | (covered via `TtioVerify` flag set; no standalone) |
| PQC keygen / sig / kem / hdf5-sign / hdf5-verify | `ttio-pqc` | `objc/Tools/obj/TtioPQCTool` | `global.thalion.ttio.tools.PQCTool` |
| Genomic test fixture writer (M82 3×3) | inline (test creates fixture) | `objc/Tools/obj/TtioWriteGenomicFixture` | `global.thalion.ttio.tools.TtioWriteGenomicFixture` |
| Compound-dataset dumper (M51) | `python -m ttio.tools.dump_identifications` | `objc/Tools/obj/TtioDumpIdentifications` | `global.thalion.ttio.tools.DumpIdentifications` |
| JCAMP-DX dump (M73) | inline (uses `ttio.importers.jcamp_dx.read_spectrum`) | `objc/Tools/obj/TtioJcampDxDump` | inline `M73Driver` (compiled at test time) |
| Transport encode / decode | `python -m ttio.tools.transport_encode_cli` / `transport_decode_cli` | `objc/Tools/obj/TtioTransportEncode` / `TtioTransportDecode` | `global.thalion.ttio.tools.TransportEncodeCli` / `TransportDecodeCli` |
| Transport server | `python -m ttio.tools.transport_server_cli` | `objc/Tools/obj/TtioTransportServer` | (no standalone main) |

---

## 4. Fixture inventory

Cross-language harnesses share these fixtures. Each fixture is owned by
one harness or fixture-generation script; do not regenerate them
ad-hoc.

| Fixture | Owner | Used by |
|---|---|---|
| `python/tests/fixtures/genomic/m87_test.{bam,bai,sam}` | `regenerate_m87_bam.sh` | `test_m87_cross_language.py`, `objc/Tests/TestM87BamImporter.m`, Java `BamReaderTest` |
| `python/tests/fixtures/genomic/m88_test.{bam,bai,sam}` | `regenerate_m88_fixtures.sh` | `test_m88_cross_language.py`, `objc/Tests/TestM88CramBamRoundTrip.m`, Java `CramBamRoundTripTest` |
| `python/tests/fixtures/genomic/m88_test.{cram,crai}` | `regenerate_m88_fixtures.sh` | `test_m88_cross_language.py` (M88.1 path), ObjC + Java siblings |
| `python/tests/fixtures/genomic/m88_test_reference.fa{,.fai}` | `regenerate_m88_fixtures.sh` | M88.1 CRAM dispatch tests (all 3 langs) |
| `python/tests/fixtures/genomic/m82_100reads.tio` | `fixtures/genomic/generate.py` | M82 3×3 matrix expected baseline |
| `python/tests/fixtures/genomic/m86_codec_*.tio` (8 fixtures) | `regenerate_m86_*.py` | M86 codec wiring byte-exact tests (all 3 langs) |
| `python/tests/fixtures/codecs/rans_{a,b,c}_o{0,1}.bin` | inline in `test_m83_rans.py` | M83 Python + ObjC `TestM83Rans` + Java `RansTest` |
| `python/tests/fixtures/codecs/base_pack_{a,b,c,d}.bin` | inline in `test_m84_base_pack.py` | M84 Python + ObjC `TestM84BasePack` + Java `BasePackTest` |
| `python/tests/fixtures/codecs/quality_{a,b,c,d}.bin` | inline in `test_m85_quality.py` | M85a Python + ObjC `TestM85Quality` + Java `QualityTest` |
| `python/tests/fixtures/codecs/name_tok_{a,b,c,d}.bin` | inline in `test_m85b_name_tokenizer.py` | M85b Python + ObjC `TestM85bNameTokenizer` + Java `NameTokenizerTest` |
| `conformance/jcamp_dx/uvvis_ramp25_{pac,sqz,dif}.jdx` | `conformance/jcamp_dx/generate.py` | M76 byte-parity gates (all 3 langs) |
| `conformance/two_d_cos/{dynamic,sync,async}.csv` | hand-curated | M77 float-tolerance gates (all 3 langs) |
| `conformance/mztab_features/{proteomics,metabolomics}.mztab` | hand-curated | M78 parser conformance (all 3 langs) |
| `objc/Tests/Fixtures/ttio/{minimal_ms,full_ms,nmr_1d,encrypted,signed}.tio` | ObjC build (per-milestone) | `test_cross_compat.py` (Python reads), back-compat archive |
| `objc/Tests/Fixtures/genomic/m87_test.{bam,sam}` + `m88_test.{bam,cram,*.fa}` | regenerated alongside Python copies | ObjC BAM/CRAM tests |

---

## 5. Coverage gap callouts

The following features have NO cross-language verification today.
Each is cross-referenced to the V-series milestone (if any) that
addresses it.

* **M18 v2 HMAC signature, Java side.** Python↔ObjC has a real
  `TtioSign` round-trip; Java has no equivalent end-to-end exchange
  (only same-process ProtectionTest). → Add a Java sign tool + matrix
  cell. Fits naturally under V4 (edge cases) or a follow-up M18.1.

* **M18 reverse direction** (Python signs → ObjC verify-as-CLI). Today
  the test is a documented placeholder pending a `--verify-signature`
  flag on `TtioVerify`. → Trivial follow-up; not in any V milestone.

* **M24 chromatograms cross-lang.** Only the ObjC fixture path is
  guard-railed; no Java side. → Belongs with M91 multi-omics
  integration when chromatograms get end-to-end coverage.

* **M25/M47 key rotation, real cross-process exchange.** Today the
  parity test is structural in-process. → V8 (HDF5 corruption /
  resilience) is the closest fit; could also add as M25.1.

* **M51 Numpress payload byte-exactness.** Cross-lang only checks
  *that the file reads back*, not that the Numpress-compressed bytes
  are identical between writers. → Worth documenting as known debt;
  V7 (codec-layer cross-language CLIs) would close this if exercised.

* **M62-x / M64.5 ObjC↔Java direct compare.** Today both readers are
  individually compared against Python; no direct ObjC-vs-Java assert.
  Transitively pinned via Python pivot, so this is a low-priority gap.
  → No V milestone planned.

* **M67 transport ObjC↔Java direct.** Same shape as above; Python is
  always the pivot. → No V milestone planned.

* **M73 ObjC↔Java JCAMP-DX direct.** Each is compared to Python;
  direct ObjC↔Java assert absent. → Low priority; transitively pinned.

* **M76 cross-language *writer* byte-equality.** The Python file
  asserts equality with the golden; the ObjC and Java siblings do the
  same. The implicit contract is "all three produce the golden", which
  is byte-exact 3-way *via the golden* but not via direct subprocess
  pipe. → Working as designed; no gap.

* **M77 2D-COS cross-language direct subprocess.** Each language
  reads the same CSV fixtures and asserts allclose against the same
  expected values. Not direct cross-process; "transitive via fixture"
  is the contract. → Working as designed.

* **M78 mzTab cross-language direct subprocess.** Same shape as M77.
  → Working as designed.

* **M82 byte-exact `.tio` across writers.** HDF5 chunk layout differs
  between writers (heuristic chunking); only field-equal is achievable
  without coordinating chunk parameters. → V7 (codec-layer CLI) could
  add a normalised-chunk variant, but probably not worth the complexity.

* **M83 / M84 / M85a / M85b codec-layer cross-language CLI** (encode
  in lang A, decode in lang B via stdin/stdout pipe). Today each
  language verifies *against the committed fixture bytes*; there's no
  direct A→B pipe. → **V7** explicitly tracks this; deferred until
  M86 implicit coverage proves insufficient.

* **MS-fixture archive Java-side.** Java does not ingest the
  `objc/Tests/Fixtures/ttio/*.tio` back-compat archive. → Add a
  parametric Java test mirroring `test_python_reads_every_objc_fixture`.
  Fits under V4 or as a one-off follow-up.

* **CI doesn't enforce that all 3 builds run** for every cross-lang
  test. Today the harnesses skip when ObjC or Java isn't built;
  `cross-compat` job builds both, but the per-suite matrix doesn't
  fail when, say, the ObjC half is skipped. → V1 (coverage) +
  follow-up reporting tweak.

---

## 6. Maintenance protocol

When a new milestone adds cross-language behaviour:

1. Add (or extend) a harness file under
   `python/tests/integration/`, `python/tests/validation/`, or as a
   sibling Java/ObjC test.
2. Add (or update) a row in §2 with the contract level achieved.
3. Add CLI tools to §3 if new mains were introduced.
4. Add fixtures to §4 with their owning generation script.
5. If any cross-language coverage is intentionally deferred, add a
   bullet under §5 with the rationale + V-series cross-reference.
6. The HANDOFF template (future addendum, V3 follow-up) will require
   a checkbox: "Updated `docs/cross-language-matrix.md`?
   (yes / N/A — does not add cross-language behaviour)".

---

*Last hand-curated 2026-04-26 against `main` @ `a53d0e2`. Inventory
covers 24 cross-language harnesses across 22 distinct features.*
