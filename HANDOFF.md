# HANDOFF — no active reference-impl milestone

**As of 2026-05-24.** The TTI-O three-language reference
implementation (`objc/`, `python/`, `java/`) and the JavaFX desktop
client (`tio-browser/`) have no active milestone handoff. v1.0.0
shipped 2026-05-04; the surface (format, codecs, transport,
encryption, importers/exporters, Workbench Client SDK + GUI panels
W1–W6) is stable. Ongoing post-v1.0 work appears in
`CHANGELOG.md` § `[Unreleased]` and ships as small follow-up PRs
rather than coordinated multi-language milestones.

The recent in-flight workstream visible in the log was **FD-1**
(server-side encrypted-pipeline processing), which spans this repo
and `tti-workbench-server`. The reference-impl-side phases shipped
through this repo are:

| Phase | Scope | Status | Spec proof |
|---|---|---|---|
| **A-1 / A-2 / A-3 / A-4** | Multi-recipient `ProtectionMetadata` wire format in Python / Java / ObjC + cross-language conformance vectors | ✅ shipped 2026-05-21 / 22 | [`2026-05-21-fd1-phase-a-multi-recipient-protection-metadata-spec.md`](docs/superpowers/specs/2026-05-21-fd1-phase-a-multi-recipient-protection-metadata-spec.md) |
| **B-1 / B-2** | Client envelope API (`upload_encrypted_multi` / `uploadEncryptedMulti`) in Python + Java | ✅ shipped 2026-05-22 | — |
| **C-0** | Standalone ObjC key-wrap primitive (byte-compat with Java + Python) | ✅ shipped 2026-05-22 | — |
| **C-2a / C-2a-4** | `server_kek_id` field in `ProtectionMetadata` (all 3 langs) + byte-parity vectors | ✅ shipped 2026-05-22 | [`2026-05-22-fd1-c2a-server-kek-id-spec.md`](docs/superpowers/specs/2026-05-22-fd1-c2a-server-kek-id-spec.md) |
| **D+** | Server pipeline (decrypt → process → re-encrypt for researcher) | ⏳ active in `tti-workbench-server` (not this repo) | — |

The most recent reference-impl-side surface (PRs #161 + #162 +
**#163**, the ObjC + Python + Java **per-AU decrypt-in-place**
APIs) unblocks FD-1's D-1 pipeline step on the server side: the
legacy `decryptInPlace` path was a silent no-op on per-AU
containers, so the server pipeline ran on still-encrypted data
and Phase E's "round-trip" was a false positive (documented in
`tti-workbench-server` #41). PR #163 (`5462489d`) closed out the
gap by adding genomic-run signal-channel coverage to all three
languages — `dataset_id` continues from the MS loop into the
genomic loop so the AAD matches the encrypt path exactly, and all
three languages now unconditionally strip the per-AU feature
flags + `@encrypted` after a successful decrypt.

---

## When to overwrite this file

This `HANDOFF.md` is replaced *per active milestone* — the git
history (`git log -- HANDOFF.md`) shows that pattern (M81 →
M82 → … → M88.1 → this stub). When a new multi-language
milestone kicks off (e.g. an `M97` codec, or a coordinated
FD-2 plan landing in this repo), overwrite this file with the
milestone's plan + task table; otherwise small post-v1.0
follow-ups go to PRs + CHANGELOG only.

For ongoing work not coordinated through HANDOFF, see:

- `CHANGELOG.md` § `[Unreleased]` — what's landed since the last
  tag.
- `WORKPLAN.md` — milestone history + binding decisions.
- `docs/superpowers/specs/` — spec proofs for wire-format-breaking
  or wire-format-extending changes (e.g. FD-1 A / C-2a).
- `docs/superpowers/plans/` — implementation plans for shipped
  milestones (kept as historical record).
- `tti-workbench-server` repository — daemon-side workstreams
  (FD-1 D+, S-series milestones, etc.) which the reference-impl
  side only feeds (via this repo's client SDK + ProtectionMetadata
  wire format).
