# HANDOFF — M88: CRAM Importer + BAM/CRAM Exporters

**Scope:** Three new classes per language: `CramReader` (CRAM
input via `samtools view -h --reference`), `BamWriter`
(GenomicRun → SAM text → `samtools view -b`), `CramWriter`
(GenomicRun → SAM text → `samtools view -C --reference`). Reuses
the M87 subprocess-delegation pattern; adds reference-FASTA
handling for CRAM and writer-side SAM line formatting from
`AlignedRead`. Three languages with one cross-language
conformance fixture (synthetic 2-chromosome reference + matching
BAM/CRAM fixtures).

**Branch from:** `main` after the M87 docs (`238b90d`).

**IP provenance:** Pure subprocess wrapping. Reuses M87's
`samtools` delegation pattern. SAM text format per the public
SAMv1 spec; CRAM details handled entirely by samtools. No
htslib source consulted or linked.

---

## 1. Background and dependencies

M87 shipped the read direction for SAM/BAM. M88 closes the
interop loop:

1. **CRAM import** — needed because CRAM is the modern reference-
   compressed sequencing format used by the 1000 Genomes Project,
   GA4GH RefGet workflows, and increasingly by clinical
   pipelines that need ~50% smaller files than BAM.
2. **BAM export** — round-trip support for the most common
   exchange format. Lets a TTI-O `.tio` file be re-emitted as
   BAM for tools that don't speak `.tio`.
3. **CRAM export** — same as BAM export but with reference-
   compressed output. Needs a reference FASTA at write time.

`samtools 1.19.2` was installed in M87 — the same binary
handles all three new code paths. CRAM additionally requires a
reference FASTA file (or a RefGet HTTP endpoint, which TTI-O
does NOT support in v0; FASTA path only).

---

## 2. Design

### 2.1 CramReader (extends BamReader pattern)

```python
class CramReader(BamReader):
    def __init__(self, path: str, reference_fasta: str): ...
```

The constructor takes both the CRAM path and a reference FASTA
path. `to_genomic_run(...)` invokes:

```
samtools view -h --reference <reference_fasta> <cram_path> [region]
```

Subprocess output is parsed identically to `BamReader.to_genomic_run`
— same SAM text format. The only difference is the `--reference`
flag.

### 2.2 BamWriter

```python
class BamWriter:
    def __init__(self, path: str): ...

    def write(
        self,
        run: WrittenGenomicRun,
        provenance_records: list[ProvenanceRecord] | None = None,
        sort: bool = True,
    ) -> None: ...
```

Emits a BAM file from a `WrittenGenomicRun`. Internally:

1. Build the SAM header from the run's metadata:
   - `@HD\tVN:1.6\tSO:coordinate` (when `sort=True`) or `\tSO:unsorted`.
   - `@SQ\tSN:<chrom>\tLN:<length>` for each unique chromosome
     observed in the run. Length is taken from the chromosome
     dictionary if available; otherwise defaults to `2147483647`
     (max int32) since SAM requires `LN:` but TTI-O doesn't
     always know the true reference length.
   - `@RG\tID:rg1\tSM:<sample_name>\tPL:<platform>` (one line)
     when sample_name and/or platform is set.
   - `@PG\tID:<entry.software>\tPN:<entry.software>\tCL:<entry.parameters>`
     for each provenance record.
2. For each read `i` in the run, emit a SAM alignment line
   with all 11 columns: QNAME, FLAG, RNAME, POS, MAPQ, CIGAR,
   RNEXT, PNEXT, TLEN, SEQ, QUAL. Tab-separated, no optional
   tag columns in v0.
3. Stream the SAM text via stdin to `samtools view -bS -`
   (the trailing `-` reads from stdin). If `sort=True`, also
   pipe through `samtools sort -O bam -o <path>`. If
   `sort=False`, write directly to `<path>` via samtools.

The `provenance_records` parameter lets the caller supply
provenance separately (since Python's `WrittenGenomicRun`
carries it as a record component but Java/ObjC don't — see M87
convergent decision).

### 2.3 CramWriter (extends BamWriter pattern)

```python
class CramWriter(BamWriter):
    def __init__(self, path: str, reference_fasta: str): ...
```

Same as BamWriter but invokes `samtools view -CS --reference
<reference_fasta> -` (or `samtools sort -O cram --reference`).

### 2.4 SAM line formatting

Each line is exactly 11 tab-separated fields:

```
QNAME\tFLAG\tRNAME\tPOS\tMAPQ\tCIGAR\tRNEXT\tPNEXT\tTLEN\tSEQ\tQUAL\n
```

Field formatting:
- **QNAME**: `read_names[i]`. Empty string is invalid in SAM
  (use `*` if unset).
- **FLAG**: `flags[i]` as decimal integer (range 0..65535).
- **RNAME**: `chromosomes[i]`. Use `*` for unmapped (already
  the case in TTI-O).
- **POS**: `positions[i]` as decimal integer (1-based; 0 =
  unmapped).
- **MAPQ**: `mapping_qualities[i]` as decimal integer (0..255).
- **CIGAR**: `cigars[i]`. Use `*` if unset.
- **RNEXT**: `mate_chromosomes[i]`. M87 expanded `=` to RNAME
  on read; the writer **collapses** `RNEXT == RNAME` to `=`
  per Binding Decision §136 (smaller SAM, lossless on
  round-trip via M87's expansion rule).
- **PNEXT**: `mate_positions[i]` as decimal integer. M87
  reads `-1` as "no mate" but SAM uses `0` for the same
  meaning — the writer maps `-1` → `0`.
- **TLEN**: `template_lengths[i]` as decimal integer (signed).
- **SEQ**: bytes from `sequences[offsets[i]:offsets[i]+lengths[i]]`,
  decoded as ASCII. If `lengths[i] == 0`, emit `*`.
- **QUAL**: bytes from `qualities[offsets[i]:offsets[i]+lengths[i]]`,
  encoded as ASCII (Phred+33 — but TTI-O already stores raw
  Phred bytes that match SAM's encoding directly). If
  `lengths[i] == 0`, emit `*`.

### 2.5 Sort behaviour

By default the writer sorts by coordinate (chromosome then
position) via `samtools sort -O bam`. When `sort=False`, the
writer emits unsorted BAM (header `SO:unsorted`). CRAM with
unsorted output is unusual but supported by samtools; the
writer matches BAM behaviour.

For round-trip round trips, sorting causes the read order in
the output BAM to potentially differ from the input
GenomicRun's order — tests must compare by read name (QNAME)
rather than by position-in-array.

### 2.6 Round-trip semantics

**Lossless fields** on round-trip (BAM → GenomicRun → BAM):
- All 11 SAM columns (QNAME through QUAL) for each read.
- @SQ entries for chromosomes the run touches.
- @RG (the first one TTI-O parsed; multi-RG aggregation is
  out of scope per M87 §133).

**Lossy / not preserved**:
- Optional SAM tag fields (12+) — discarded by M87, NOT
  re-emitted by M88.
- @PG accumulation — each round trip adds samtools and TTI-O
  @PG entries; the user-supplied `bwa` entry stays but the
  list grows.
- Original sort order if `sort=True` (default).

**CRAM-specific lossless concerns**:
- Sequence: lossless via reference-compressed encoding.
- Quality: lossless under default samtools settings (no
  `--output-fmt-option lossy_names`).
- Read names: lossless (unless `--output-fmt-option
  lossy_names=1`, which TTI-O does NOT enable).

### 2.7 Reference FASTA handling

For M88 v0:
- The reference FASTA path is a positional argument to
  `CramReader` and `CramWriter` constructors.
- Path resolution is the caller's responsibility (no env-var
  fallback, no auto-discovery).
- Must be a real filesystem path (no http:// / s3:// /
  RefGet endpoints in v0).
- samtools handles `.fai` index requirement — if missing,
  samtools writes one to the same directory as the FASTA on
  first read. No TTI-O-side index management.

A small synthetic reference FASTA (~2 KB total, 1 kb each for
chr1 and chr2) is committed as a fixture for testing.

---

## 3. Binding Decisions (continued from M87 §131–§135)

| #   | Decision | Rationale |
|-----|----------|-----------|
| 136 | The BAM writer **collapses** `mate_chromosome == chromosome` to the SAM `=` shorthand for `RNEXT`. M87's reader expanded `=` to RNAME; the writer reverses this for round-trip canonicality. | Smaller SAM/BAM (one byte vs N bytes per same-chrom mate). Lossless under M87 + M88 round-trips because the expansion/collapse pair preserves semantics. |
| 137 | The default sort behaviour is **coordinate-sorted output** (`sort=True`). | BAM consumers (samtools index, IGV, GATK) expect coordinate-sorted; emitting unsorted by default would make every TTI-O-written BAM unusable downstream without a separate `samtools sort` step. The `sort=False` parameter is available for callers who explicitly need the input order preserved. |
| 138 | `mate_positions[i] == -1` (TTI-O's "no mate" sentinel) is **mapped to `0` on write** (SAM's convention). M87's reader does not symmetrically map SAM 0 → -1 because SAM 0 is overloaded ("position 0" is also the sentinel for unmapped POS); the writer's mapping is a one-way normalisation to SAM convention. | TTI-O's `-1` was an internal convention (the M82 schema chose -1 because it doesn't collide with any valid 1-based position). SAM uses 0 for the same meaning. The writer normalises on output to ensure samtools accepts the stream. |
| 139 | Reference FASTA path is a **positional constructor argument** for CRAM read/write. No env-var fallback, no `RefGet` HTTP support in v0. | Keep API simple; reference resolution is a known headache for genomic tools and TTI-O doesn't need to solve it again. Callers who need fancier resolution wrap the constructor. |
| 140 | Optional SAM tag fields (cols 12+) are **NOT preserved** through the M88 round trip. | M87's reader discards them (Binding Decision §134's spirit); M88's writer doesn't have them to re-emit. A future milestone could store + re-emit tags via a new `WrittenGenomicRun.optional_tags: list[list[str]]` field; not in M88 scope. |

---

## 4. API surface

### 4.1 Python — `python/src/ttio/importers/cram.py` + `python/src/ttio/exporters/bam.py` + `python/src/ttio/exporters/cram.py`

```python
from ttio.importers.cram import CramReader
from ttio.exporters.bam import BamWriter
from ttio.exporters.cram import CramWriter

# CRAM read:
reader = CramReader("alignments.cram", "reference.fa")
run = reader.to_genomic_run(name="sample1")

# BAM write:
writer = BamWriter("output.bam")
writer.write(run, provenance_records=run.provenance_records)

# CRAM write:
cram_writer = CramWriter("output.cram", "reference.fa")
cram_writer.write(run, provenance_records=run.provenance_records)
```

### 4.2 Objective-C — `objc/Source/Import/TTIOCramReader.{h,m}` + `objc/Source/Export/TTIOBamWriter.{h,m}` + `objc/Source/Export/TTIOCramWriter.{h,m}`

```objc
@interface TTIOCramReader : TTIOBamReader
- (instancetype)initWithPath:(NSString *)path
              referenceFasta:(NSString *)referenceFasta;
@end

@interface TTIOBamWriter : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (BOOL)writeRun:(TTIOWrittenGenomicRun *)run
   provenanceRecords:(NSArray<TTIOProvenanceRecord *> *)provenance
                sort:(BOOL)sort
               error:(NSError **)error;
@end

@interface TTIOCramWriter : TTIOBamWriter
- (instancetype)initWithPath:(NSString *)path
              referenceFasta:(NSString *)referenceFasta;
@end
```

### 4.3 Java

```java
public class CramReader extends BamReader {
    public CramReader(Path path, Path referenceFasta) { ... }
}

public class BamWriter {
    public BamWriter(Path path) { ... }
    public void write(WrittenGenomicRun run,
                      List<ProvenanceRecord> provenance,
                      boolean sort) throws IOException { ... }
}

public class CramWriter extends BamWriter {
    public CramWriter(Path path, Path referenceFasta) { ... }
}
```

---

## 5. Reference + cross-language fixture

### 5.1 Synthetic reference FASTA

Commit `python/tests/fixtures/genomic/m88_test_reference.fa`:

```
>chr1
ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT
ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT
... [repeat ACGT for 1000 bases total per chromosome] ...
>chr2
TGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCA
TGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCATGCA
... [repeat TGCA for 1000 bases total per chromosome] ...
```

Total: ~2 KB committed binary (deterministic; the
`regenerate_m88_reference.sh` script regenerates from a small
inline Python one-liner).

The `.fai` index (`m88_test_reference.fa.fai`) is regenerated
on first use by samtools. We commit the reference but NOT the
index (lets samtools build it deterministically on each
machine).

### 5.2 BAM and CRAM fixtures

`python/tests/fixtures/genomic/m88_test.bam` — 5 reads aligned
to the synthetic reference (4 perfect-match on chr1 around
position 100, 1 perfect-match on chr2 around position 200).
Built from a small SAM source `m88_test.sam` via:

```sh
samtools view -bS m88_test.sam > m88_test.bam
samtools index m88_test.bam
```

`python/tests/fixtures/genomic/m88_test.cram` — same data
encoded as CRAM:

```sh
samtools view -CS --reference m88_test_reference.fa m88_test.sam > m88_test.cram
samtools index m88_test.cram
```

All four files (`.fa`, `.bam`, `.bam.bai`, `.cram`,
`.cram.crai`) committed; regeneration via
`regenerate_m88_fixtures.sh`.

The `.cram.crai` index file is needed for region-filter tests
on CRAM input.

---

## 6. Tests

### 6.1 Python — `python/tests/test_m88_cram_bam_round_trip.py`

14 pytest cases (skip-the-file pattern from M87 if samtools is
missing):

1. **`test_cram_read_full`** — read `m88_test.cram` with
   `CramReader`, verify `len(run.read_names) == 5` and all
   per-read scalars match the expected values from the SAM
   source.
2. **`test_cram_read_region`** — region-filter CRAM read on
   `chr1:100-200` returns the 4 chr1 reads.
3. **`test_bam_write_basic`** — write a `WrittenGenomicRun`
   to a temp `.bam`, then read it back with `BamReader` and
   verify all read names + positions round-trip. Don't
   assert byte-equality of the BAM file (samtools may add
   @PG entries).
4. **`test_bam_write_unsorted`** — same with `sort=False`,
   verify the read order in the output matches the input
   order.
5. **`test_bam_write_with_provenance`** — write with explicit
   `provenance_records=[ProvenanceRecord(...)]`, read back,
   verify the entry appears in the parsed @PG chain.
6. **`test_cram_write_basic`** — write a `WrittenGenomicRun`
   to a temp `.cram` (with reference), read back with
   `CramReader`, verify round-trip.
7. **`test_cram_write_with_reference`** — write CRAM, then
   try reading WITHOUT the reference path; verify samtools
   raises (CRAM needs the reference; this is samtools
   behaviour, not TTI-O).
8. **`test_round_trip_bam_to_bam`** — full BAM → GenomicRun →
   BAM round trip. Read both BAMs back through `BamReader`
   and verify equality of all per-read scalar arrays + the
   sequences/qualities byte buffers (excluding @PG count
   which grows by 2 per write).
9. **`test_round_trip_cram_to_cram`** — full CRAM → GenomicRun
   → CRAM round trip. Same comparison method.
10. **`test_round_trip_cross_format`** — BAM → GenomicRun →
    CRAM, then CRAM → GenomicRun → BAM. End state should
    match the start (modulo @PG growth).
11. **`test_mate_collapse_to_equals`** — verify the BAM
    writer collapses `mate_chromosome == chromosome` to `=`
    in the SAM stream by writing then reading the raw SAM
    via `samtools view -h` and parsing.
12. **`test_mate_position_negative_one_to_zero`** — verify
    the writer maps `-1` mate positions to `0` per Binding
    Decision §138.
13. **`test_cram_reader_missing_reference`** — `CramReader`
    constructed without a reference path raises a clear
    error (or one is required-arg in the constructor; pick
    one and test).
14. **`test_writer_produces_valid_sam`** — write a BAM, then
    `samtools view <bam>` returns valid SAM text (parseable
    by `samtools view -h` round trip).

### 6.2 ObjC — `objc/Tests/TestM88CramBamRoundTrip.m`

Same 14 cases. Skip the whole file if `samtools` is not on
PATH (reuse the M87 detection helper from
`TTIOBamReader.m`).

### 6.3 Java — `java/src/test/java/global/thalion/ttio/exporters/CramBamRoundTripTest.java`

Same 14 cases. JUnit 5 with `Assumptions.assumeTrue(samtoolsAvailable())`
(reuse M87's `BamReader.isSamtoolsAvailable()` static probe).

### 6.4 Cross-language conformance

Extend `python/tests/integration/test_m87_cross_language.py`
into a new
`python/tests/integration/test_m88_cross_language.py` that:

1. Reads `m88_test.bam` in each of the three languages
   (sanity check; same as M87's existing harness on the
   different fixture).
2. **Writes** `m88_test.bam` from a known
   `WrittenGenomicRun` in each of the three languages,
   reads each output back via `BamReader`, and dumps via
   `bam_dump`. Asserts all three written-and-re-read BAMs
   produce byte-identical canonical JSON.
3. Same for CRAM via `CramReader` / `CramWriter`.

The cross-language assertion is on the **decoded JSON**
(field-equality), not on the raw BAM/CRAM bytes (which
differ by samtools-injected @PG entries and timestamps).

---

## 7. Documentation

### 7.1 `docs/vendor-formats.md`

Extend the SAM/BAM section (added in M87) with new
subsections "CRAM input (M88)" and "BAM/CRAM export (M88)"
covering:
- Reference FASTA requirement for CRAM read/write.
- Lossless round-trip guarantees and known lossy pitfalls
  (samtools' `--output-fmt-option lossy_names`, etc.).
- Sort behaviour (default coordinate-sorted; `sort=False`
  preserves input order).
- The mate-position normalisation (-1 → 0 on write per §138).
- The mate-chromosome collapse (`==` chromosome → `=` per
  §136).

### 7.2 README.md

Add CRAM importer + BAM/CRAM exporter rows to the existing
Importers and Exporters lists.

### 7.3 CHANGELOG.md

M88 entry under `[Unreleased]`.

### 7.4 WORKPLAN.md

M88 status flipped from planned to SHIPPED.

---

## 8. Out of scope

- **CRAM with embedded reference** — TTI-O requires an
  external reference FASTA. samtools' embedded-reference CRAM
  mode is not exposed in v0.
- **RefGet HTTP endpoints** — the FASTA path is a filesystem
  path only. RefGet integration is a future milestone.
- **htslib direct linking** — subprocess-only continues from
  M87.
- **Optional SAM tag fields** — see Binding Decision §140.
  Future milestone could add a `WrittenGenomicRun.optional_tags`
  field.
- **Multi-RG splitting on write** — only one @RG emitted per
  output BAM/CRAM. Future scope.
- **Lossy CRAM modes** — `--output-fmt-option
  lossy_names=1` and quality-binning CRAM modes are NOT
  exposed. Always lossless.
- **Streaming write for huge runs** — same as M87, the full
  GenomicRun is materialised in memory before SAM text is
  generated.
- **Index file management** — samtools auto-builds `.fai`,
  `.bai`, `.crai` as needed. TTI-O doesn't try to be smart
  about it.

---

## 9. Acceptance Criteria

### Python
- [ ] All existing tests pass (zero regressions vs `238b90d`).
- [ ] All 14 new tests in
      `python/tests/test_m88_cram_bam_round_trip.py` pass.
- [ ] `m88_test_reference.fa`, `m88_test.sam`, `m88_test.bam`,
      `m88_test.bam.bai`, `m88_test.cram`, `m88_test.cram.crai`
      fixtures committed.
- [ ] `regenerate_m88_fixtures.sh` script committed and
      executable.
- [ ] `CramReader` + `BamWriter` + `CramWriter` import
      successfully without samtools installed (only methods
      that invoke samtools require it).

### Objective-C
- [ ] All existing tests pass (zero regressions vs the 2532
      PASS baseline + 2 pre-existing M38 Thermo failures).
- [ ] 14 new test methods in `TestM88CramBamRoundTrip.m`
      pass when samtools is available; skip cleanly when not.
- [ ] ≥ 30 new assertions.

### Java
- [ ] All existing tests pass (zero regressions vs the 529/0/0/0
      baseline → ≥ 543/0/0/0 after M88).
- [ ] 14 new test methods in `CramBamRoundTripTest.java` pass
      when samtools is available; skip cleanly when not.

### Cross-Language
- [ ] All three implementations produce field-equal canonical
      JSON when reading the M88 BAM/CRAM fixtures.
- [ ] BAMs written by each language round-trip to identical
      decoded JSON when read back.
- [ ] `docs/vendor-formats.md` SAM/BAM section extended with
      CRAM read/write coverage.
- [ ] `README.md` exporters list updated.
- [ ] `CHANGELOG.md` M88 entry committed.
- [ ] `WORKPLAN.md` M88 status flipped to SHIPPED.

---

## 10. Gotchas

158. **CRAM reads need the reference; CRAM writes need the
     reference; CRAM seeks need the index.** All three are
     samtools-side concerns — TTI-O just passes paths
     through. Tests must commit the reference + index files
     OR rely on samtools auto-building them on first use.

159. **samtools sort writes a temp file to the BAM's
     directory by default.** For tmp_path tests, this means
     the sort happens in a directory that pytest controls;
     no special handling needed.

160. **The mate-chromosome collapse (§136) interacts with
     samtools sort.** When samtools sorts by coordinate,
     mate-chromosome RNEXT may shift order; the collapse
     happens in the SAM text TTI-O generates BEFORE samtools
     sees it, so samtools' sort doesn't affect the collapse
     decision.

161. **CRAM round-trips through TTI-O are NOT byte-identical
     CRAM bytes** (samtools may use different compression
     parameters, container layouts, etc. across runs). The
     cross-language assertion is on **decoded fields**, not
     raw CRAM bytes. Same rationale as the M87 cross-language
     harness.

162. **Quality bytes in SAM/BAM/CRAM are Phred+33 ASCII**;
     TTI-O stores raw Phred bytes. The encoding mismatch:
     SAM stores ASCII `'I'` (= 73 decimal = Phred 40 +33), TTI-O
     stores raw byte 40. The reader (M87) already handles
     this (subtracts 33 from each char's ASCII value to get
     raw Phred). The writer (M88) must add 33 to each raw
     Phred byte to get the ASCII character.

     Wait — re-check M87 behaviour. The M87 reader stores
     SAM's QUAL field bytes directly into the qualities
     buffer (subtracts 33? or stores as-is?). Verify with
     the M87 fixture's `qualities_md5`: the expected MD5 is
     over raw Phred bytes (after −33 conversion) OR over
     ASCII bytes (no conversion). The implementer must
     check the M87 implementation and match its convention
     so M88's write reverses it correctly.

163. **TLEN can be very negative** (signed int32 — values
     down to -2^31). Don't accidentally truncate to int16 or
     uint32 anywhere in the SAM line formatter.

164. **The SAM spec requires fixed column ordering**;
     samtools rejects malformed SAM. The writer's per-read
     line builder must always emit all 11 columns even when
     fields are empty (use `*` or `0` per spec rather than
     skipping).

165. **CRAM file extensions matter to samtools.** `.cram`
     extension triggers CRAM mode auto-detection; `.bam`
     triggers BAM. Always honour the user-supplied path
     extension; don't auto-rename.

166. **The reference FASTA must match the BAM's @SQ
     entries.** If a BAM was aligned against `chr1`
     (length 248956422 in GRCh38) but the user passes a
     reference where chr1 has a different length, samtools
     errors out. TTI-O doesn't validate this — error
     surfaces from the samtools subprocess.
