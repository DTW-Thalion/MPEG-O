# HANDOFF — M87: SAM/BAM Importer

**Scope:** Read SAM and BAM (Sequence Alignment/Map) files via
the `samtools view` subprocess and convert them to
`WrittenGenomicRun` instances suitable for handing to
`SpectralDataset.write_minimal(genomic_runs=...)`. First
importer milestone for the genomic data path; first M86-era
milestone introducing an external runtime dependency
(`samtools`). Three languages (Python reference, ObjC
normative, Java parity), with one cross-language conformance
fixture.

**Branch from:** `main` after the M80–M86 doc sweep
(`3ac8bd7`).

**IP provenance:** The TTI-O code wraps samtools as a
subprocess; no htslib source is linked or consulted. SAM/BAM
format parsing is from the public SAMv1 specification (Li et
al. 2009 / SAMv1 spec at https://samtools.github.io/hts-specs).
The subprocess approach mirrors the existing M53 Bruker timsTOF
importer pattern (which subprocesses `opentims-bruker-bridge`
from non-Python languages).

---

## 1. Background

The M83–M86 codec stack established that genomic data has
first-class support in TTI-O. M87 closes the loop on the input
side: callers can now ingest existing SAM/BAM files (the
de-facto exchange format for aligned sequencing reads) and
write them as `.tio` files using whatever codec choices best
fit their workload.

`samtools` is the canonical reference implementation for
SAM/BAM I/O. Linking htslib directly would couple TTI-O to a
specific htslib version (and add a build dependency that's
non-trivial in some environments). Subprocess wrapping is
simpler:

- TTI-O's three languages all have well-tested subprocess APIs.
- Format parsing happens in plain text (SAM is tab-delimited);
  no binary wire-format work needed in any language.
- `samtools view -h <file>` writes SAM text to stdout for both
  SAM and BAM input — one parser handles both formats.
- New samtools versions roll out independently without TTI-O
  coupling.

The cost: samtools must be on PATH at runtime. The package is
in every major OS distribution (`apt install samtools`,
`brew install samtools`, etc.) and is also the install target
for any user who's also using BAM tools elsewhere.

---

## 2. Design

### 2.1 The BamReader API

Each language exposes a `BamReader` class:

```python
class BamReader:
    def __init__(self, path: str): ...

    def to_genomic_run(
        self,
        name: str = "genomic_0001",
        region: str | None = None,
        sample_name: str | None = None,
    ) -> WrittenGenomicRun: ...
```

- `path`: filesystem path to a SAM or BAM file. samtools auto-
  detects format from magic bytes.
- `name`: the genomic-run name (becomes the subgroup name
  under `/study/genomic_runs/<name>/`).
- `region`: optional region filter passed through to
  `samtools view` as positional argument
  (e.g. `"chr1:1000-2000"` or `"*"` for unmapped reads).
- `sample_name`: optional override for the run's
  `sample_name` attribute. If None, derived from `@RG SM:` in
  the SAM header (or empty string if no @RG present).

The returned `WrittenGenomicRun` is the existing M82 write-
side container; the caller can hand it directly to
`SpectralDataset.write_minimal(genomic_runs={name: run})`.

### 2.2 The SamReader thin wrapper

```python
class SamReader(BamReader):
    """Convenience wrapper for SAM input.

    Functionally identical to BamReader (samtools auto-detects
    format); kept as a separate class for API clarity in
    callsites that explicitly handle SAM text input.
    """
    pass
```

No format conversion needed — `samtools view -h <file>` reads
both SAM and BAM. SamReader exists purely as a discoverable
API for users searching for "SAM importer".

### 2.3 Subprocess invocation

Each language invokes:

```
samtools view -h [region] <path>
```

stdout is consumed line-by-line. Lines starting with `@` are
header lines; everything else is an alignment record.

Subprocess lifecycle:
- Start the subprocess in `to_genomic_run()`.
- Stream stdout (line-buffered) into the parser.
- Wait for exit; check returncode == 0.
- On non-zero exit, raise an error including stderr content.

The subprocess is invoked via:
- Python: `subprocess.Popen(["samtools", "view", "-h", path,
  *([region] if region else [])], stdout=subprocess.PIPE,
  stderr=subprocess.PIPE, text=True)`.
- ObjC: `NSTask` with `setLaunchPath:`/`setArguments:`/
  `setStandardOutput:`/`setStandardError:`.
- Java: `ProcessBuilder(["samtools", "view", "-h", path,
  ...])`.

### 2.4 SAM header parsing

Header lines are tab-separated `@TAG\tKEY:VALUE\tKEY:VALUE...`
records. M87 parses three tag types:

**`@SQ` — reference sequence dictionary:**
```
@SQ\tSN:chr1\tLN:248956422
```
Map `SN:` (sequence name) → reference chromosome list. The
TTI-O `reference_uri` field is set to the first @SQ's `SN:`
value in v0 of M87 (or to a comma-joined list — pick simplest
that round-trips a single-reference input). For BAMs with many
@SQ entries (typical for whole-genome alignments), the
chromosome list goes into the `GenomicIndex.chromosomes`
parallel array per-read.

**`@RG` — read group:**
```
@RG\tID:rg1\tSM:NA12878\tPL:ILLUMINA\tLB:lib1
```
Map `SM:` (sample) → `WrittenGenomicRun.sample_name`. Map
`PL:` (platform) → `WrittenGenomicRun.platform`. Multiple @RG
lines: take the first one for v0 of M87 (caller can override
via the `sample_name` parameter if needed).

**`@PG` — program/tool used:**
```
@PG\tID:samtools\tPN:samtools\tVN:1.19.2\tCL:samtools view ...
```
Each @PG entry becomes a `ProvenanceRecord` in the run's
`provenance_records` list. The `software` field is `PN:`, the
`parameters` field is `CL:` (the original command line),
`timestamp_unix` is the file's mtime (since SAM doesn't carry
per-record timestamps).

`@HD` (header version) and `@CO` (comments) are read but not
mapped to TTI-O fields in v0.

### 2.5 SAM alignment record parsing

Each alignment line is tab-separated with at least 11 fields
(extra optional tag fields are ignored in v0):

| Field | Name  | TTI-O destination                                      |
|-------|-------|--------------------------------------------------------|
| 1     | QNAME | `read_names[i]`                                        |
| 2     | FLAG  | `flags[i]` (uint32; cast from int)                     |
| 3     | RNAME | `chromosomes[i]` (or `"*"` for unmapped)               |
| 4     | POS   | `positions[i]` (int64; SAM is 1-based, TTI-O follows SAM)|
| 5     | MAPQ  | `mapping_qualities[i]` (uint8)                         |
| 6     | CIGAR | `cigars[i]`                                            |
| 7     | RNEXT | `mate_chromosomes[i]` (`"="` expanded to RNAME)        |
| 8     | PNEXT | `mate_positions[i]` (int64; -1 if unmapped)            |
| 9     | TLEN  | `template_lengths[i]` (int32; signed; 0 if unpaired)   |
| 10    | SEQ   | concatenated into `sequences` byte array (`"*"` → empty contribution) |
| 11    | QUAL  | concatenated into `qualities` byte array (`"*"` → empty) |

**Per-read offsets/lengths into the per-base channels:**
`offsets[i]` = sum of all prior `lengths`; `lengths[i]` = number
of bases for read `i`. For reads where SEQ is `"*"` (sequence
not stored in the BAM), `lengths[i] = 0` and the read
contributes 0 bytes to `sequences` and `qualities`.

### 2.6 RNEXT special handling

In SAM, `RNEXT == "="` means "same chromosome as RNAME". Some
parsers preserve the literal `"="`; TTI-O **expands** it to
the actual chromosome name (so downstream consumers don't need
to remember the RNEXT-vs-RNAME convention). Documented in
Binding Decision §131.

### 2.7 The 1-based position convention

SAM is 1-based for positions; BED-derived tools are typically
0-based. TTI-O preserves the SAM convention (positions are
1-based in `positions[i]` and `mate_positions[i]`); a value of
`0` means "no position" (matches SAM's convention for unmapped
reads where POS is sometimes recorded as `0`). Documented in
Binding Decision §132.

### 2.8 Error handling

samtools-not-on-PATH, file-not-found, malformed-SAM-line, and
samtools-non-zero-exit all raise informative errors with
language-native exception types. Each error message includes:
- The path being read (for "file not found" / "samtools failed")
- The relevant SAM line + line number (for parse errors)
- The captured stderr (for non-zero samtools exit)

samtools-not-on-PATH is detected at first call (via `which`
or `subprocess.run(["samtools", "--version"])`). The error
message includes installation guidance for the major OSes.

---

## 3. Binding Decisions (continued from M86 Phase F §125–§130)

| #   | Decision | Rationale |
|-----|----------|-----------|
| 131 | When SAM's `RNEXT` field is `"="`, the importer **expands** it to the actual `RNAME` value rather than preserving the literal `"="`. | Makes downstream consumers self-contained — they don't need to remember the RNEXT-vs-RNAME convention to interpret `mate_chromosome`. The expansion is lossless because the original information (RNAME) is also stored. |
| 132 | TTI-O preserves SAM's **1-based** position convention. `positions[i]` is the SAM 1-based POS field directly. A value of `0` means "no/unknown position" (matches SAM's convention for unmapped reads). | Matches the upstream format; avoids a class of bugs that comes from converting between 1-based and 0-based and back. Existing M82 code paths assume positions are 1-based per SAM. |
| 133 | When the BAM has multiple `@RG` lines, M87 takes the **first** one for `sample_name` and `platform`. Caller can override via the `sample_name` parameter. | Most BAMs have one @RG. Multi-RG BAMs (e.g. merged from multiple libraries) are an advanced case; v0 picks one and lets the caller override. Future scope could expose all @RG as a list. |
| 134 | `samtools` is invoked as a **subprocess**, not via libhtslib bindings. | Avoids coupling TTI-O to a specific htslib version. Subprocess approach is well-tested via M53 Bruker timsTOF importer. Trade-off: ~50ms subprocess startup overhead per import (acceptable for typical batch-import workloads). |
| 135 | `samtools` not on PATH raises a clear error with installation guidance at first use, NOT at import time. The `BamReader` class is importable without samtools installed; only `to_genomic_run()` requires it. | Lets users `import ttio.importers.bam` without samtools installed (e.g. for documentation generation, type checking). The library doesn't refuse to load just because the runtime tool is missing. |

---

## 4. API surface

### 4.1 Python — `python/src/ttio/importers/bam.py`

```python
from ttio.importers.bam import BamReader

reader = BamReader("/path/to/alignments.bam")
run = reader.to_genomic_run(name="sample1", sample_name="NA12878")

# Optional region filter:
chr1_only = reader.to_genomic_run(name="chr1", region="chr1")
chr1_window = reader.to_genomic_run(name="window", region="chr1:1000-2000")
unmapped = reader.to_genomic_run(name="unmapped", region="*")

# Hand to the writer:
SpectralDataset.write_minimal(
    "out.tio",
    title="Test run",
    isa_investigation_id="ISA-001",
    genomic_runs={run.name: run},
)
```

`SamReader` is exported from `python/src/ttio/importers/sam.py`
as a thin subclass.

### 4.2 Objective-C — `objc/Source/Import/TTIOBamReader.{h,m}`

```objc
@interface TTIOBamReader : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (TTIOWrittenGenomicRun *)toGenomicRunWithName:(NSString *)name
                                          region:(NSString *)region
                                      sampleName:(NSString *)sampleName
                                           error:(NSError **)error;
@end
```

`TTIOSamReader` subclass in `Import/TTIOSamReader.{h,m}`.

### 4.3 Java — `java/src/main/java/global/thalion/ttio/importers/BamReader.java`

```java
public class BamReader {
    public BamReader(Path path) { ... }
    public WrittenGenomicRun toGenomicRun(String name) { ... }
    public WrittenGenomicRun toGenomicRun(String name, String region) { ... }
    public WrittenGenomicRun toGenomicRun(String name, String region, String sampleName) { ... }
}
```

`SamReader` subclass in `importers/SamReader.java`.

---

## 5. Test fixture

A small SAM/BAM fixture committed to
`python/tests/fixtures/genomic/m87_test.sam` (source) and
`python/tests/fixtures/genomic/m87_test.bam` (binary) with a
companion script `regenerate_m87_bam.sh` that converts the SAM
to BAM via `samtools view -bS`.

Fixture content (10 reads, mix of mapped + unmapped):

```sam
@HD	VN:1.6	SO:coordinate
@SQ	SN:chr1	LN:248956422
@SQ	SN:chr2	LN:242193529
@RG	ID:rg1	SM:M87_TEST_SAMPLE	PL:ILLUMINA	LB:lib1
@PG	ID:bwa	PN:bwa	VN:0.7.17	CL:bwa mem ref.fa reads.fq
r000	99	chr1	1000	60	100M	=	1100	200	ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT	IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
r001	147	chr1	1100	60	100M	=	1000	-200	TGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCA	HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH
r002	0	chr1	2000	30	50M50S	*	0	0	ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN	IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII
r003	99	chr2	5000	60	100M	=	5100	200	GCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCAT	JJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJ
r004	147	chr2	5100	60	100M	=	5000	-200	ATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGC	GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG
r005	4	*	0	0	*	*	0	0	*	*
r006	77	*	0	0	*	*	0	0	ACGTACGTAC	IIIIIIIIII
r007	141	*	0	0	*	*	0	0	TGCATGCATG	HHHHHHHHHH
r008	16	chr1	3000	30	100M	*	0	0	ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT	FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
r009	0	chr1	4000	30	100M	*	0	0	ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT	EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
```

Properties of this fixture:
- 10 reads total: 4 paired-mapped (r000-r001 + r003-r004), 1 with soft-clip (r002), 1 wholly unmapped with no SEQ (r005), 2 unmapped with SEQ stored (r006, r007), 2 single-end mapped (r008, r009).
- Two chromosomes (chr1, chr2) for `@SQ` parsing coverage.
- Single @RG (sample = `M87_TEST_SAMPLE`, platform = ILLUMINA).
- Single @PG (program = bwa).
- Mixed CIGARs (`100M`, `50M50S`) for cigars-channel coverage.
- Mixed sequences (pure ACGT, plus N runs in r002) for sequences-channel coverage.

Total bytes contributed to `sequences`: 100 + 100 + 100 + 100 + 100 + 0 + 10 + 10 + 100 + 100 = 720 bytes.

The `.bam` binary is generated from this `.sam` via:
```sh
samtools view -bS m87_test.sam > m87_test.bam
```

Both files committed; the `.sam` is the authoritative spec
(human-readable) and the `.bam` is the binary form the tests
actually parse.

---

## 6. Tests

### 6.1 Python — `python/tests/test_m87_bam_importer.py`

11 pytest cases:

1. **`test_samtools_available`** — verify `samtools --version`
   succeeds; if not, skip the rest of the file with a clear
   xfail marker. (`pytest.skipif(...)` at module level on the
   `samtools` PATH check.)
2. **`test_read_full_bam`** — read `m87_test.bam`, verify
   `len(run.read_names) == 10`, all 10 read names present in
   order (`r000`..`r009`).
3. **`test_read_positions`** — verify `run.positions` matches
   the SAM POS column for each read (1000, 1100, 2000, 5000,
   5100, 0, 0, 0, 3000, 4000).
4. **`test_read_chromosomes`** — verify
   `run.chromosomes == ["chr1", "chr1", "chr1", "chr2", "chr2",
   "*", "*", "*", "chr1", "chr1"]`.
5. **`test_read_flags`** — verify `run.flags` (99, 147, 0,
   99, 147, 4, 77, 141, 16, 0).
6. **`test_read_mapping_qualities`** — verify
   `run.mapping_qualities` = (60, 60, 30, 60, 60, 0, 0, 0,
   30, 30).
7. **`test_read_cigars`** — verify
   `run.cigars == ["100M", "100M", "50M50S", "100M", "100M",
   "*", "*", "*", "100M", "100M"]`.
8. **`test_read_sequences_concat`** — verify
   `run.sequences` is the concatenation of the 10 SEQ values
   (with `"*"` reads contributing 0 bytes); total length
   should be 720 bytes per the fixture properties.
9. **`test_read_mate_info`** — verify mate fields:
   `mate_chromosomes` = `["chr1", "chr1", "*", "chr2",
   "chr2", "*", "*", "*", "*", "*"]` (RNEXT `"="` expanded to
   RNAME per Binding Decision §131); `mate_positions` = `[1100,
   1000, 0, 5100, 5000, 0, 0, 0, 0, 0]`; `template_lengths` =
   `[200, -200, 0, 200, -200, 0, 0, 0, 0, 0]`.
10. **`test_read_metadata_from_header`** — verify
    `run.sample_name == "M87_TEST_SAMPLE"` (from @RG),
    `run.platform == "ILLUMINA"` (from @RG),
    `run.reference_uri` is set (from @SQ; either "chr1" or
    "chr1,chr2" — pin in the test based on impl choice).
11. **`test_round_trip_through_writer`** — read the BAM,
    write it back as a `.tio` via
    `SpectralDataset.write_minimal`, reopen, iterate reads,
    verify each `aligned_read.read_name`, `.position`,
    `.cigar`, etc. matches the original. Closes the loop:
    BAM → WrittenGenomicRun → `.tio` → GenomicRun →
    AlignedRead.
12. **`test_region_filter`** — read with
    `region="chr2:5000-5200"`, verify only 2 reads come back
    (r003, r004 — both on chr2 in that window).
13. **`test_region_unmapped`** — read with `region="*"`,
    verify only the 4 unmapped/single-end reads come back.
14. **`test_provenance_from_pg`** — verify
    `run.provenance_records` contains at least one entry
    derived from the `@PG` line; the entry's `software` field
    is `"bwa"` and `parameters` includes `"bwa mem ref.fa
    reads.fq"`.
15. **`test_sam_input`** — instantiate `SamReader` (or
    `BamReader`) on `m87_test.sam`, get the same 10-read
    result as the BAM. Verifies samtools's auto-format detection.
16. **`test_samtools_missing_error`** — patch `subprocess` to
    simulate `samtools` not on PATH; verify the resulting
    error message includes installation guidance for at least
    one of {apt, brew, conda}.

### 6.2 ObjC — `objc/Tests/TestM87BamImporter.m`

Same 16 cases. Skip the whole test file if `samtools` is not
on PATH (`getenv("PATH")` + `access(X_OK)` walk, or
`NSTask` with `samtools --version` returning non-zero). Wire
into `TTIOTestRunner.m` as `START_SET("M87: BAM importer")`.

Target ≥ 30 new assertions.

### 6.3 Java — `java/src/test/java/global/thalion/ttio/importers/BamReaderTest.java`

Same 16 cases. JUnit 5; use `@Disabled` or
`assumeThat(samtools is on PATH)` to skip if samtools is
missing.

### 6.4 Cross-language conformance

The `.bam` fixture is committed once under
`python/tests/fixtures/genomic/m87_test.bam`. ObjC tests
read it from `objc/Tests/Fixtures/genomic/m87_test.bam`
(verbatim copy). Java tests read it from
`java/src/test/resources/ttio/fixtures/genomic/m87_test.bam`
(verbatim copy).

Each implementation produces the same `WrittenGenomicRun`
shape: same `read_count`, same per-read scalar arrays
(positions, flags, mapping_qualities, etc.), same
`sequences` byte buffer. The cross-language assertion is
**equality of decoded fields**, not byte-exact wire format
(since the input is BAM, not a TTI-O codec stream).

A new `m87_cross_language` integration test in
`python/tests/integration/test_m87_cross_language.py`
subprocesses the ObjC `TtioBamDump` and Java `BamDump` CLIs
(both new in M87) on the fixture and diffs their canonical-
JSON output against the Python BamReader's JSON dump. The
CLIs emit the parsed run as canonical JSON for byte-compare;
test fails if any field diverges.

---

## 7. CLI tools

Each language ships a small `bam_dump` CLI for the cross-
language conformance harness:

- Python: `python -m ttio.importers.bam_dump <bam_path>` →
  canonical JSON to stdout.
- ObjC: `TtioBamDump <bam_path>` → canonical JSON to stdout.
- Java: `java -cp ... BamDump <bam_path>` → canonical JSON to
  stdout.

The JSON shape is fixed across all three:

```json
{
  "name": "genomic_0001",
  "read_count": 10,
  "sample_name": "M87_TEST_SAMPLE",
  "platform": "ILLUMINA",
  "reference_uri": "chr1",
  "read_names": ["r000", "r001", ...],
  "positions": [1000, 1100, ...],
  "chromosomes": ["chr1", "chr1", ...],
  "flags": [99, 147, ...],
  "mapping_qualities": [60, 60, ...],
  "cigars": ["100M", "100M", ...],
  "mate_chromosomes": ["chr1", "chr1", ...],
  "mate_positions": [1100, 1000, ...],
  "template_lengths": [200, -200, ...],
  "sequences_md5": "<md5 hex of concatenated sequences>",
  "qualities_md5": "<md5 hex of concatenated qualities>",
  "provenance_count": 1
}
```

The `sequences_md5` / `qualities_md5` are MD5 hashes of the
full byte buffers — short fixed-width fingerprints rather than
embedding hundreds of bytes of base data in the JSON.

---

## 8. Documentation

### 8.1 `docs/vendor-formats.md`

Add a new section "SAM/BAM (M87)" documenting:
- Subprocess-based design (samtools required at runtime).
- Install instructions for major OSes (`apt install samtools`,
  `brew install samtools`, `conda install -c bioconda
  samtools`).
- Field mapping table (SAM column → TTI-O field).
- Header-line handling (@SQ, @RG, @PG).
- Region filter syntax (samtools-native: `chr1:start-end`,
  `*` for unmapped).
- Cross-language CLI usage (`bam_dump`).

### 8.2 README.md

Add SAM/BAM importer to the existing **Importers** list (one
line bullet, parallel to the existing mzML / nmrML / JCAMP-DX
/ Bruker timsTOF / Thermo entries).

### 8.3 `CHANGELOG.md`

Add M87 entry under `[Unreleased]`. Update the Unreleased
header to mention M87.

### 8.4 `WORKPLAN.md`

Update Phase 5 status: M87 status flipped from "planned" to
SHIPPED with commits and test counts.

### 8.5 Python `pyproject.toml`

Add a note in the "Optional dependencies" section: the
`bam`/`sam` importer requires the system tool `samtools`
(not a PyPI package) — install via OS package manager. No
PyPI dependency added (the BamReader is pure Python on top of
subprocess).

---

## 9. Out of scope

- **CRAM reading.** Reading CRAM via samtools requires a
  reference FASTA. M88 covers CRAM import (separate
  milestone).
- **BAM/SAM writing.** TTI-O is the read direction in M87.
  M88 covers the BAM/CRAM writers.
- **htslib direct linking.** Subprocess via samtools is the
  Phase 5 design choice (Binding Decision §134). A future
  optimisation milestone could add htslib-Java / pysam fast
  paths, but M87 does NOT.
- **Optional SAM tag fields.** Fields 12+ on each alignment
  line (NM:, MD:, etc.) are ignored in v0. A future milestone
  could expose them as a `tags` field on `AlignedRead`.
- **Multi-RG aggregation.** Only the first @RG is parsed in
  v0. Caller can override via `sample_name=`.
- **Region filter syntax extensions.** The region string is
  passed through to samtools verbatim — whatever samtools
  accepts, TTI-O accepts. No TTI-O-side parsing.
- **Streaming write.** The full `WrittenGenomicRun` is built
  in memory before being passed to the writer. For very
  large BAMs (10⁹+ reads), a streaming writer would be
  needed; deferred future scope.

---

## 10. Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `3ac8bd7`).
- [ ] All 16 new tests in `python/tests/test_m87_bam_importer.py`
      pass.
- [ ] `m87_test.sam` and `m87_test.bam` fixtures committed.
- [ ] `python -m ttio.importers.bam_dump <bam>` CLI works and
      emits the JSON shape from §7.
- [ ] Importing `ttio.importers.bam` works without samtools
      installed (only `to_genomic_run()` requires it).

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2477
      PASS baseline + 2 pre-existing M38 Thermo failures).
- [ ] 16 new test methods in `TestM87BamImporter.m` pass when
      samtools is available; skip cleanly when not.
- [ ] `TtioBamDump` CLI compiled and present.
- [ ] ≥ 30 new assertions.

### Java
- [ ] All existing tests pass (zero regressions vs the 512/0/0/0
      baseline → ≥ 528/0/0/0 after M87).
- [ ] 16 new test methods in `BamReaderTest.java` pass when
      samtools is available; skip cleanly when not.
- [ ] `BamDump` Maven exec target present.

### Cross-Language
- [ ] All three implementations produce the same canonical JSON
      from `m87_test.bam` (`test_m87_cross_language.py` green).
- [ ] `docs/vendor-formats.md` SAM/BAM section committed.
- [ ] `README.md` Importers list mentions SAM/BAM.
- [ ] `CHANGELOG.md` M87 entry committed.
- [ ] `WORKPLAN.md` M87 status flipped to SHIPPED.

---

## 11. Gotchas

149. **samtools is a runtime dependency, not a build
     dependency.** Each language must check at first use
     (NOT at import time — Binding Decision §135) and raise
     a clear error with installation guidance if missing.
     `import ttio.importers.bam` succeeds even on systems
     without samtools.

150. **samtools subprocess startup is ~50ms.** For a single
     `to_genomic_run()` call this is negligible; for batch
     workloads importing thousands of small BAMs, consider
     batching at the caller level. M87 doesn't optimise for
     this case.

151. **samtools writes BAM-format errors to stderr, not
     stdout.** When `samtools view` exits non-zero, the
     stderr buffer must be captured and included in the
     raised error. Otherwise debugging "what went wrong with
     this BAM" is opaque.

152. **SAM lines can contain literal tab characters in
     optional tags.** v0 of M87 parses only fields 1-11
     (whitespace-split with maxsplit=11 in Python; equivalent
     in ObjC/Java) and discards trailing fields. Avoid the
     "split on all tabs" trap that breaks on malformed
     optional-tag fields.

153. **The CIGAR string `"*"` means "no CIGAR".** Same for
     SEQ and QUAL. The importer must store `"*"` literally
     in `cigars[i]` (don't normalise to empty string) so
     downstream consumers can distinguish "no info" from
     "empty alignment".

154. **POS = 0 is valid.** SAM uses POS 0 for unmapped reads
     (not -1). Don't confuse with `mate_position == -1` for
     "no mate" (which is a TTI-O convention, not a SAM
     convention). The importer maps SAM POS directly into
     `positions[i]` (1-based; 0 = unmapped/no-position).

155. **TLEN is signed.** SAM's TLEN can be negative
     (template-end-side reads). `template_lengths[i]` is
     int32 and preserves the sign.

156. **Cross-language tests must skip gracefully when
     samtools is missing.** The implementation works without
     samtools; the *tests* require it. Don't fail the whole
     test suite on a samtools-less CI runner.

157. **The fixture `.bam` file is binary** — committed as a
     binary blob to the repo. Regeneration script (`.sh`)
     that runs `samtools view -bS m87_test.sam > m87_test.bam`
     is committed alongside so anyone can rebuild. The `.sam`
     is the authoritative spec (human-readable).
