# HANDOFF — M98 AssemblyGraph

**As of 2026-08-24.** M98 adds the one new container primitive the
T2T assembly pipeline needs: a GFA 1.x assembly graph stored at
`/study/assembly_graphs/<name>/` (format-spec §11a, binding
decisions §88–§92) with byte-exact re-emission, so the graph is a
signed, encryptable object the curation round-trip can edit.
Phase 0 proved the mapping on a synthetic full-surface GFA plus all
10 hifiasm 0.25.0 outputs of a 6,734-read HG002 chr1 window before
any ObjC work. Branch: `m98-assembly-graph`.

| Task | Scope | Status | Spec proof |
|---|---|---|---|
| **Phase 0** | Python prototype of the GFA 1.x ↔ HDF5 mapping; byte-exact round-trip on hifiasm output before any ObjC or Java work | ✅ 2026-08-24 (`tools/prototypes/m98_gfa_hdf5/`) | required before the layout froze (wire-change gate) |
| **A ObjC** | Value classes (`TTIOGraphSegment` / `TTIOGraphLink` / `TTIOGraphPath` / `TTIOWrittenAssemblyGraph` validating init), `TTIOGfaReader` / `TTIOGfaWriter`, storage write (`writeAssemblyGraph:named:toStudyGroup:`), `writeMinimalToPath:` overload + `opt_assembly_graph`, `assemblyGraphs` accessor on both open paths | ✅ implemented + tested | — |
| **B Python** | `ttio.assembly` mirrors, `importers/gfa.GfaReader` / `exporters/gfa.GfaWriter`, `write_minimal(assembly_graphs=...)`, `ds.assembly_graphs`; fixed the HDF5 provider's list-of-dict compound write for VL-string fields | ✅ implemented + tested | — |
| **C Java** | `assembly` package mirrors, `importers.GfaReader` / `exporters.GfaWriter`, `SpectralDataset.create` overload + accessor on both open + both create paths; fixed the HDF5 compound adapter's `writeAll` to accept the `List<Map>` row shape | ✅ implemented + tested | — |
| **D Conformance** | `GfaDump` canonical-JSON CLI ×3 with `--write-tio` / `--emit-gfa` modes; 3×3 writer × emitter container matrix over the synthetic + `fx_bp_r_utg.gfa.gz` fixtures, byte-exact in every cell (`tests/validation/test_m98_gfa_matrix.py`) | ✅ 22/22 cells | — |
| **E Protection** | Per-AU encryption walkers cover `segments/sequences` (one AU per segment record, codec-decoded before slicing, raw write-back on decrypt-in-place) and `sign_assembly_graph` / `verify_assembly_graph` ×3 | ✅ implemented + tested in 3 SDKs | — |
| **F Docs** | format-spec §11a, binding decisions §88–§92, CHANGELOG, cross-language-matrix rows, feature-flags entry, this file | ✅ | — |

Layout summary: per graph `@gfa_version` / `@producer` /
`@final_newline` attributes; `segments/records` +
`segments/sequences` (BASE_PACK / RANS_ORDER1 via `@compression`),
`links`, `paths`, `extras`, `line_index` (0=S 1=L 2=P 3=extra).
Empty tables are absent; `@final_newline` is the structural marker.
Parsing is structural (S≥3 / L≥6 / P≥4 fields, everything else
verbatim into extras) so unknown record types survive the
round-trip unparsed.

Acceptance state (workplan M98): GFA round-trip byte-exact on
hifiasm output — ✅ (Verkko output remains to be exercised when a
Verkko run of the mini-genome exists); 3×3 conformance green — ✅;
signed + per-AU-encrypted graph decrypts in place in all three
languages — ✅ per-language (cross-language exchange of an
*encrypted* graph container has no CLI surface yet; the plaintext
container matrix is cross-language); Bandage opens the exported
GFA — manual check, to be noted on the PR.

Known limits, deliberate: `decrypt_per_au` (the read-only,
not-in-place decrypt) and the M90.4 by-region APIs do not walk
`assembly_graphs`; streaming graphs and a `.tis` packet type are
out of scope per binding decision T6.

Suite state at handoff: ObjC 5225 pass / 3 known-environmental
TestM90Final failures; Java 1631 tests 0 failures; Python failing
set identical to the pre-M98 baseline (the worktree-artefact set)
with the M98 additions green.

---

## When to overwrite this file

This `HANDOFF.md` is replaced *per active milestone* — the git
history (`git log -- HANDOFF.md`) shows that pattern (M81 →
M82 → … → M97 → this). When the next multi-language milestone kicks
off, overwrite this file with the milestone's plan + task table;
otherwise small post-v1.0 follow-ups go to PRs + CHANGELOG only.

For ongoing work not coordinated through HANDOFF, see:

- `CHANGELOG.md` § `[Unreleased]` — what's landed since the last
  tag.
- `WORKPLAN.md` — milestone history + binding decisions (§88–§92
  are M98's).
- `tti-workbench-server` repository — daemon-side workstreams.
