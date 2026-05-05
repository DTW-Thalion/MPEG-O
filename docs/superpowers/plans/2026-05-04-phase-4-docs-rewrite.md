# Phase 4: Docs Rewrite to v1.0.0

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (chosen) to implement this plan task-by-task.

**Goal:** Rewrite all top-level + format-spec docs so they describe the v1.0.0 codec stack and wire format. CHANGELOG collapses to a single `v1.0.0 — first stable release` entry (option A — no public release ever happened, all prior history is internal). Stale pre-v1.0 version markers (`v0.3`, `v0.7`, `v1.1`, `v1.2`, "M93 v1", etc.) get scrubbed where they describe live behavior, but kept inside historical context (benchmark reports, design specs).

**Architecture:** Pure docs work — no source/test code touched. Sequence the rewrites largest-first (CHANGELOG → format-spec → ARCHITECTURE → README → codec docs → other) so each subsequent file can cross-reference the one just done. Run the full test suite at the end as a no-regression sanity gate.

**Tech Stack:** Markdown only. No build/test framework changes. Working directory `~/TTI-O` in WSL Ubuntu (`wsl -d Ubuntu -- bash -c '...'` with absolute paths per `feedback_pwd_mangling_in_nested_wsl`).

---

## Codec table for v1.0 (the new authoritative truth — paste into rewrites)

| Id | Symbol               | Name                          | Status in v1.0 | Channels             |
|---:|----------------------|-------------------------------|:--------------:|----------------------|
| 0  | NONE                 | none / passthrough            | live           | any                  |
| 1  | ZLIB                 | HDF5 deflate filter           | live           | any                  |
| 2  | LZ4                  | HDF5 filter id 32004          | live           | any                  |
| 3  | NUMPRESS_DELTA       | TTIO numpress-delta           | live           | numeric MS channels  |
| 4  | RANS_ORDER0          | rANS order-0                  | live           | sequences/qualities/cigars/integer/mate_info_chrom |
| 5  | RANS_ORDER1          | rANS order-1                  | live           | same as RANS_ORDER0  |
| 6  | BASE_PACK            | 2-bit ACGT pack + sidecar     | live           | sequences            |
| 7  | QUALITY_BINNED       | Illumina-8 bin                | live           | qualities            |
| 8  | _RESERVED_8          | (was NAME_TOKENIZED, removed) | reserved       | n/a                  |
| 9  | _RESERVED_9          | (was REF_DIFF v1, removed)    | reserved       | n/a                  |
| 10 | _RESERVED_10         | (was FQZCOMP_NX16, removed)   | reserved       | n/a                  |
| 11 | DELTA_RANS_ORDER0    | delta + rANS-O0 (M95)         | live           | sortable integer     |
| 12 | FQZCOMP_NX16_Z       | CRAM-mimic quality, V4 only   | live           | qualities            |
| 13 | MATE_INLINE_V2       | inlined mate_info v2 (M86 PhF) | live          | mate_info compound   |
| 14 | REF_DIFF_V2          | reference-diff v2             | live           | sequences            |
| 15 | NAME_TOKENIZED_V2    | 8-substream tokenizer v2      | live           | read_names           |

Reserved ids 8/9/10 retain their slots on the wire (Java enum ordinal stability). Python `Compression(8|9|10)` raises ValueError; ObjC enum drops the symbols entirely.

---

## Pre-flight

- [ ] **Step 0.1: Verify HEAD + clean tree**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git status --short && git rev-parse --short HEAD'
```

Expected: only `?? docs/superpowers/plans/...` (the Phase 3 + 4 plan docs) untracked; HEAD `6f6a255`.

---

## Task 1: Replace CHANGELOG.md with single v1.0.0 entry

**Files:**
- Modify: `CHANGELOG.md` (3612 lines → ~140 lines)

**Goal content:** A single `## [v1.0.0] — 2026-05-04 — first stable release` entry that summarises capabilities by category (format / codecs / encryption / signing / multi-omics modalities / language bindings). No predecessor entries. The reader's takeaway: "this is the first release, started here." Pre-v1.0 archaeology lives in git history.

- [ ] **Step 1.1: Read existing CHANGELOG to extract the capability summary that v1.10 ships**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && head -220 CHANGELOG.md'
```

Note: the v1.10/v1.9/v1.8/v1.7 sections describe genomic codec milestones; the v1.2.0 section describes the multi-omics core. Synthesize these into a single bullet list under v1.0.0 categories.

- [ ] **Step 1.2: Replace CHANGELOG.md content**

Use Write to overwrite `CHANGELOG.md` with this structure:

```markdown
# CHANGELOG

All notable changes to the TTI-O multi-omics data standard reference
implementation. Future releases will follow Keep-a-Changelog conventions.

## [v1.0.0] — 2026-05-04 — first stable release

This is the first stable release of TTI-O. The format string is
`ttio_format_version = "1.0"`; container ABI, codec wire formats,
encryption envelope, and digital-signature canonicalisations are all
contractually frozen at this point.

### Format
- HDF5-backed `.tio` container; opaque `study/` group; per-modality
  `ms_runs/`, `genomic_runs/`, `chromatograms/`, optional
  `nmr_runs/` / `image_cubes/`.
- Deterministic write order; all readers + writers across Python,
  Java, Objective-C produce byte-identical output for the same input.
- Per-AU encryption (AES-256-GCM), digital signatures (HMAC-SHA256
  + post-quantum ML-DSA via liboqs), wrapped-key blob (M25), feature-
  flag preamble, ISA-Tab investigation linkage.

### Codecs (live)
- Generic byte: `RANS_ORDER0` (id 4), `RANS_ORDER1` (id 5).
- Genomic sequences: `BASE_PACK` (id 6, 2-bit ACGT + sidecar),
  `REF_DIFF_V2` (id 14, reference-aligned slice-based).
- Genomic qualities: `QUALITY_BINNED` (id 7, Illumina-8 bins),
  `FQZCOMP_NX16_Z` (id 12, V4 only — CRAM-mimic adaptive quality).
- Genomic read names: `NAME_TOKENIZED_V2` (id 15, 8-substream
  multi-token).
- Genomic mate info: `MATE_INLINE_V2` (id 13).
- Sortable integer channels: `DELTA_RANS_ORDER0` (id 11).
- HDF5 native: `ZLIB` (id 1, deflate level 6 default), `LZ4`
  (id 2, filter 32004), `NUMPRESS_DELTA` (id 3, MS m/z numpress).
- Reserved (wire-format slots, no live codec): ids 8 / 9 / 10.

### Modalities
- Mass spectrometry (LC-MS, MS-image cubes, ion mobility), nuclear
  magnetic resonance (1-D + native 2-D), vibrational imaging
  (Raman/IR), UV-Vis, two-dimensional correlation (2DCOS),
  chromatograms, genomic alignment runs (BAM/CRAM importer parity).

### Language bindings
- **Python** (`pip install ttio`): full read/write/encryption/sign;
  ctypes wrapper for the native rANS/v2-codec library.
- **Java** (Maven Central `global.thalion:ttio`): full parity;
  JNI wrapper for the same native library.
- **Objective-C** (GNUstep): full parity; native library linked
  directly; `objc/Tools/MakeFixtures` produces the canonical
  cross-language reference fixtures.

### Cross-language guarantee
- Byte-equal output for shared codec paths under the test corpora
  in `data/genomic/` (na12878 chr22, hg002 illumina/pacbio
  subsets). Verified via `pytest -m integration`; SHA256 hashes
  match Python ↔ Java ↔ Objective-C.

### Known limitations
- m89 transport bulk-mode wire format is deferred; genomic-run
  cross-language transport currently round-trips via per-channel
  v2 dispatch and pre-existing m82/m89 cross-lang transport
  conformance tests fail on the same code path.
```

(Tweak wording during execution; the example content above captures intent.)

- [ ] **Step 1.3: Verify line count is in the ~150 ballpark**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && wc -l CHANGELOG.md'
```

Expected: ~150 (was 3612).

- [ ] **Step 1.4: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add CHANGELOG.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "docs(changelog): Phase 4 — collapse to single v1.0.0 first-release entry

User authorized option A: pre-v1.0 history (v0.6.1 → v1.10) is internal
development that never had a public release. Archaeology lives in git
history; the CHANGELOG begins at v1.0.0."'
```

---

## Task 2: Update README.md to v1.0 codec descriptions

**Files:**
- Modify: `README.md` (lines 78-81 specifically; sweep for other v1-codec mentions)

The README's "Genomic compression" section (lines ~75-85) currently advertises four codecs that have either been removed or replaced:
- Line 78: `NAME_TOKENIZED` v1 (removed) — replace with `NAME_TOKENIZED_V2` (id 15).
- Line 79: "Pipeline wiring" mentions per-field mate_info subgroup decomposition (Phase F, removed in 2c) and "schema-lift" (removed) — rewrite to describe v2 pipeline.
- Line 80: `REF_DIFF` v1 (removed) — replace with `REF_DIFF_V2` (id 14).
- Line 81: `FQZCOMP_NX16_Z` mentions V1/V2/V3 dispatch (removed) and `Phase 10 / 2026-04-30` legacy-removal context (irrelevant to v1.0 readers) — rewrite to V4-only.

- [ ] **Step 2.1: Read README.md sections 70-100 to confirm exact wording**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -n "60,100p" README.md'
```

- [ ] **Step 2.2: Read full README.md**

Use Read tool on `README.md` to see all live references that may need updating beyond the four bullets.

- [ ] **Step 2.3: Edit the codec bullets to v1.0 reality**

Each bullet should describe a LIVE v1.0 codec by its v1.0 id, link to the corresponding `_v2` doc where relevant, and drop "M93/M94/Phase 10/2026-04-30" archaeology. Sample replacement for line 78:

```markdown
* **NAME_TOKENIZED_V2** (codec id 15) — 8-substream multi-token columnar
  codec for read names. FLAG / POOL_IDX / MATCH_K / COL_TYPES /
  NUM_DELTA / DICT_CODE / DICT_LIT / VERB_LIT substreams; per-block
  reset every 4096 reads; auto-picked rANS-O0 vs raw passthrough per
  substream. ~3 MB savings on chr22 NA12878. See
  [`docs/codecs/name_tokenizer_v2.md`](docs/codecs/name_tokenizer_v2.md).
```

Mirror the pattern for ref_diff_v2 (id 14) and fqzcomp_nx16_z (id 12, V4-only). For the "Pipeline wiring" bullet, drop the Phase F per-field subgroup paragraph; replace with the v2 inline `MATE_INLINE_V2` (id 13).

- [ ] **Step 2.4: Sweep for any other v1-codec references**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && grep -nE "REF_DIFF\\b|NAME_TOKENIZED\\b|fqzcomp_nx16[^_]|FQZCOMP_NX16[^_]|M93|M94 v1|Phase 10" README.md'
```

Expected after Step 2.3: the only matches reference v2 (e.g. `NAME_TOKENIZED_V2`) or are inside historical-context mentions. Address any stragglers.

- [ ] **Step 2.5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add README.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "docs(readme): Phase 4 — describe v1.0 codec stack (v2 codecs only)

NAME_TOKENIZED v1 / REF_DIFF v1 / FQZCOMP_NX16_Z V1-V3 were removed
in Phase 2c. README replaces them with NAME_TOKENIZED_V2 (id 15),
REF_DIFF_V2 (id 14), FQZCOMP_NX16_Z V4 (id 12), and MATE_INLINE_V2
(id 13) descriptions."'
```

---

## Task 3: Rewrite ARCHITECTURE.md genomic codec stack section

**Files:**
- Modify: `ARCHITECTURE.md` (line 714 §heading + table at lines 729-730 + M93 REF_DIFF discussion at lines 742-788)

The section heading currently reads "Genomic compression codec stack (M83–M86 + M93/M94/M94.Z/M95, v1.2)". This stack is unchanged in v1.0 EXCEPT the v1 codec ids (8/9/10) are reserved-only and the v2 codecs (13/14/15) are live.

- [ ] **Step 3.1: Read the section + immediate context**

Use Read tool on `ARCHITECTURE.md` for the range 700-810 to capture the full discussion.

- [ ] **Step 3.2: Update the section heading**

Drop the "v1.2" suffix; update milestone list to reflect v2 dispatch:

```markdown
## Genomic compression codec stack (M83–M86, REF_DIFF_V2, FQZCOMP_NX16_Z, NAME_TOKENIZED_V2, MATE_INLINE_V2)
```

- [ ] **Step 3.3: Replace the codec id table**

Use the codec table from the plan header (top of this file). The current table has rows for ids 8 + 9 with live-codec descriptions — rewrite as `_RESERVED_*` rows or drop them and add ids 11 + 13 + 14 + 15.

- [ ] **Step 3.4: Replace the M93 REF_DIFF discussion**

Lines 742-788 talk about "Context-aware codec interface (M93+)" with REF_DIFF v1 specifics (slice strategy, embedded reference, BASE_PACK fallback semantics). Replace with REF_DIFF_V2 description: same context-aware contract, but the v2 wire format (see `docs/codecs/ref_diff_v2.md`).

- [ ] **Step 3.5: Sweep for other stale references**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && grep -nE "M93\\b|M94 v1|REF_DIFF\\b|NAME_TOKENIZED\\b|fqzcomp_nx16[^_]|Phase 10" ARCHITECTURE.md'
```

Address every remaining match (replace with v2 codec name + id, or remove if it's archaeology).

- [ ] **Step 3.6: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add ARCHITECTURE.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "docs(architecture): Phase 4 — rewrite genomic codec stack section to v1.0 reality

Codec id table now lists ids 4-7 (live primitives) + 11 (DELTA_RANS) +
12 (FQZCOMP_NX16_Z V4) + 13/14/15 (mate_info/ref_diff/name_tokenized
v2). Ids 8/9/10 are RESERVED placeholders for wire-format slot
stability. Context-aware codec discussion describes REF_DIFF_V2 (id 14)."'
```

---

## Task 4: Rewrite format-spec.md §10.4 codec table

**Files:**
- Modify: `docs/format-spec.md` (lines 767-866, the §10.4 codec table + surrounding paragraphs)

This is the highest-traffic section in the format spec — third-party implementers read this first.

- [ ] **Step 4.1: Read the section thoroughly**

Use Read tool on `docs/format-spec.md` for lines 767-870.

- [ ] **Step 4.2: Replace §10.4 codec table**

Use the v1.0 codec table from the top of this plan. Rewrite each table row's "Transport" column to match the live codec semantics (drop "v0.12 unreleased", "v1.2", "Phase 10" historical markers).

- [ ] **Step 4.3: Rewrite the post-table prose (lines ~786-866)**

The paragraphs after the table currently sermonise about "v0.12.x post-M86 Phase D", "v1.2 / M93 adds codec id 9 (REF_DIFF) — the first context-aware codec", "M94/M95 milestones add fqzcomp-Nx16 ... and delta-encoded sorted integer channels". Collapse into a single concise block describing:
- which codec ids apply to which channels under v1.0
- the §10.5–§10.10 cross-references (which sections detail per-channel pipeline wiring)
- the cross-language byte-equal guarantee

Drop the "Note on CRAM 3.1" paragraph (line 859-865) — it's a historical Q4 2026 milestone narrative, not a v1.0 spec contract.

- [ ] **Step 4.4: Verify line count + sweep**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && wc -l docs/format-spec.md && grep -nE "M93\b|M94 v1|REF_DIFF\b|NAME_TOKENIZED\b|Phase 10|v1\.2 / M93|v1\.2 / M94|v0\.12" docs/format-spec.md | head -20'
```

Address any §10.4 strugglers; per-section rewrites for §10.5–§10.10 happen in Task 5.

---

## Task 5: Sweep format-spec.md §10.5–§10.10 + other sections for v1-codec references

**Files:**
- Modify: `docs/format-spec.md` (§10.5 codec attribute, §10.6 read_names schema-lift, §10.7 integer-channel contract, §10.8 cigars, §10.9 mate_info subgroup, §10.9b mate_info v2 inline, §10.10 ref_diff slice format, §10.10b name_tokenized v2 substreams)

The pre-2c spec described two parallel pipelines: v1 codecs (NAME_TOKENIZED schema-lift, mate_info per-field subgroup, REF_DIFF slice), and v2 codecs added "alongside". v1.0 deletes the v1 paths. The §10.6/§10.7/§10.9 sections still contain v1 schema descriptions that mislead readers.

- [ ] **Step 5.1: Inventory the per-section damage**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && grep -nE "schema.lift|Phase E|Phase F|v1 NAME_TOKENIZED|v1 REF_DIFF|v1 mate_info|subgroup writer|@subgroup_version|name-tokenized v1" docs/format-spec.md | head -30'
```

This produces the worklist for Task 5.

- [ ] **Step 5.2: §10.6 — read_names**

The pre-2c §10.6 described the NAME_TOKENIZED v1 schema-lift (compound-string → flat uint8 + length prefix). v1.0 read_names always go through `NAME_TOKENIZED_V2` (id 15) — see `docs/codecs/name_tokenizer_v2.md` for the 8-substream wire format. Replace §10.6 with a brief description that points at the v2 doc.

- [ ] **Step 5.3: §10.7 — integer channels**

§10.7 currently describes the integer↔byte serialisation contract. The CONTRACT itself is unchanged (LE-byte serialisation, ids 4 + 5 apply). But the section may still reference the removed v1.5 integer-channel signal_codec_overrides path (the one Task 4 of Phase 3 hit when regen-integer-channels.py was deleted). Verify and trim.

- [ ] **Step 5.4: §10.9 — mate_info**

§10.9 described the M82 compound + Phase F per-field subgroup decomposition. v1.0 always inlines mate_info via `MATE_INLINE_V2` (id 13). §10.9b already documents the v2 inline format. Collapse §10.9 to a forward reference: "Mate info is encoded via MATE_INLINE_V2 (id 13). See §10.9b for the wire format."

- [ ] **Step 5.5: §10.10 — ref_diff (if present)**

If a §10.10 v1 REF_DIFF section exists separate from `_v2`, drop or reduce it to a forward reference to §10.10b / `docs/codecs/ref_diff_v2.md`.

- [ ] **Step 5.6: Final sweep**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && grep -nE "schema.lift|Phase E|Phase F|v1 NAME_TOKENIZED|v1 REF_DIFF|v1 mate_info|subgroup writer|@subgroup_version|name-tokenized v1" docs/format-spec.md'
```

Expected: empty (all v1-codec narratives gone).

- [ ] **Step 5.7: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add docs/format-spec.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "docs(format-spec): Phase 4 — rewrite codec table (§10.4) + collapse v1-codec sections

§10.4 codec table now lists v1.0 ids 4-7 + 11-15; ids 8/9/10 are
RESERVED. §10.6 (read_names schema-lift), §10.9 (mate_info Phase F
subgroup), §10.10 (REF_DIFF v1) collapsed to forward references at
the corresponding _v2 sections. §10.7 integer-channel contract
trimmed of removed-in-v1.5 override narrative."'
```

---

## Task 6: Audit + edit secondary docs

**Files (audit, edit if stale):**
- `docs/M82.md` — M82 data model is unchanged in v1.0 (per Phase 2e memory); the read_names compound layout was removed but `WrittenGenomicRun` structure is intact. Sweep for v1-codec references.
- `docs/cross-language-matrix.md` — verify the cross-lang gate corpus matches what `pytest -m integration` actually runs.
- `docs/migration-guide.md` — if it describes a v0.x → v1.x migration, reframe as "There is no migration; v1.0.0 is the first stable release."
- `docs/version-history.md` — if it tracks every released format_version string, update with a single "1.0" entry; older entries describe pre-release internal milestones.
- `docs/codecs/name_tokenizer.md`, `docs/codecs/ref_diff.md`, `docs/codecs/fqzcomp_nx16.md` — Phase 2e added deprecation banners pointing at `_v2.md`. Confirm those banners are still the only content; if any v1-spec body remains, trim.
- `docs/codecs/rans.md`, `docs/codecs/base_pack.md`, `docs/codecs/quality.md`, `docs/codecs/delta_rans.md`, `docs/codecs/name_tokenizer_v2.md`, `docs/codecs/ref_diff_v2.md`, `docs/codecs/fqzcomp_nx16_z.md` — these describe live codecs; verify they don't claim "v1.2" / "Phase 10" / "M93 v1" / similar archaeology.
- `docs/feature-flags.md` — if it has per-version flag rosters, collapse to a v1.0 roster.

- [ ] **Step 6.1: Run the sweep across all secondary docs**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && grep -rnE "v1\.2\b|Phase 10|M93\b|M94 v1|REF_DIFF\b|NAME_TOKENIZED\b|fqzcomp_nx16[^_]|FQZCOMP_NX16[^_]|schema-lift|Phase F" docs/ --include=*.md | grep -v -E "^docs/(benchmarks|superpowers/specs)/" | head -40'
```

Files under `docs/benchmarks/` and `docs/superpowers/specs/` are intentionally frozen-in-time (benchmark reports + design specs); don't touch.

- [ ] **Step 6.2: Edit each flagged doc**

Address every match from Step 6.1. Pattern: replace v1-codec mentions with v2 equivalents OR remove the sentence if it's purely historical.

- [ ] **Step 6.3: Re-sweep**

Repeat Step 6.1; expected output: empty (or only matches inside benchmarks / specs).

- [ ] **Step 6.4: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add docs/ && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "docs: Phase 4 — sweep secondary docs (M82, codec docs, feature-flags, version-history) to v1.0"'
```

---

## Task 7: Run the test suites + push

**Files:** none.

Phase 4 is docs-only, so test counts must not change. This is a regression gate.

- [ ] **Step 7.1: Python suite**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/python && source .venv/bin/activate && export TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so && pytest -q --tb=no 2>&1 | tail -3'
```

Expected: `1335 passed, 11 failed, 11 skipped` (matches Phase 3 baseline).

- [ ] **Step 7.2: Java suite**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/java && mvn -q test 2>&1 | grep -E "Tests run:|BUILD" | tail -3'
```

Expected: `Tests run: 783, Failures: 0, Errors: 0, Skipped: 4`.

- [ ] **Step 7.3: ObjC suite (sanity — docs-only changes don't affect it, but verify)**

Optional: skip if Step 7.1 + 7.2 pass cleanly. If running, expect 3025 PASSED + 1 FAILED (the M94.Z perf flake).

- [ ] **Step 7.4: Push**

Per `feedback_git_push_via_windows`:

```bash
"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O" -c safe.directory="*" push origin main
```

Expected: clean push, the 5 Phase 4 commits land on `origin/main`. Wait for explicit user authorization before pushing (system requires it for main-branch pushes).

- [ ] **Step 7.5: Update memory**

Update `C:\Users\toddw\.claude\projects\C--WINDOWS-system32\memory\project_tti_o_v1_2_codecs.md` description + add a "Phase 4 SHIPPED" status block documenting the new HEAD, the 5 Phase 4 commits, and the file inventory rewrites.

---

## Self-Review

**Spec coverage:**
- CHANGELOG (option A — single v1.0.0 entry) → Task 1.
- README v1 codec descriptions → Task 2.
- ARCHITECTURE genomic codec stack + table → Task 3.
- format-spec §10.4 codec table → Task 4.
- format-spec §10.5–§10.10 v1 narrative cleanup → Task 5.
- M82 / version-history / migration-guide / codec docs / feature-flags → Task 6.
- Test-suite gate + push + memory → Task 7.

**Out of scope (intentionally):**
- `docs/benchmarks/*` — historical reports; preserved as-is.
- `docs/superpowers/specs/*` — design specs; preserved as-is.
- Source code (Python/Java/ObjC) — Phase 2 already finished the source rewrite.

**Risk notes for the executor:**
- The plan's example CHANGELOG content (Task 1.2) is illustrative; the executor should adjust wording on the fly to fit project tone.
- §10.5–§10.10 are interlocked; expect to edit multiple sections in one pass and verify with the final sweep (Step 5.6).
- If a doc under Task 6 has more rewrite needed than a quick sweep, split it into a follow-up commit rather than blocking Task 7.
