# TTI-O Version History

TTI-O ships its first stable release as **v1.0.0**. There is no
pre-v1.0 public release history; pre-v1.0 milestones were internal
development (M-numbered tracking in `WORKPLAN.md`).

For the v1.0.0 capability summary, see [`../CHANGELOG.md`](../CHANGELOG.md).

**Current release: v1.7.1 (2026-06-08)** — a post-1.7.0 performance
campaign (behavior-identical perf wins across all three SDKs, byte-output
unchanged), on top of the v1.7.0 OO design-assessment sweep across
Python / Java / ObjC. See [`../CHANGELOG.md`](../CHANGELOG.md) for the
per-release detail. The entire 1.x line is additive and non-breaking:
no `.tio` / wire / breaking-API change has been made since v1.0.0.

For format-string evolution within a single major version, see
`@ttio_format_version` in `docs/format-spec.md` §1. v1.0.0 stamps
`ttio_format_version = "1.0"`.
