# Changelog

All notable changes to Moult are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Moult aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Pre-1.0 notice.** Moult is `0.x`: the CLI, the typed JSON contracts, and
> the confidence model may still change between minor versions. Pin a version
> if you depend on the output shape. (Moult also depends on `rubydex ~> 0.2`,
> itself pre-1.0.)

## [Unreleased]

### Added
- `Moult::CloudUpload.projection` — the sanitised payload builder for the
  `moult-action` → Moult Cloud upload (allow-lists top-level keys; normalises
  the absolute `analysis.root` path; the gate report is already source-free).
- `action.yml` — the `moult-action` composite GitHub Action: runs the gate in
  CI and uploads the projected result with keyless GitHub OIDC auth.
- Open-source release setup: Apache-2.0 license, Trusted Publishing release
  workflow, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`.

### Changed
- License changed from MIT to **Apache-2.0** (adds an explicit patent grant;
  the chosen open-core core license).

## [0.1.0] - unreleased

Initial development version. The static + runtime analysis suite:

- `moult hotspots` — complexity (ABC) × git churn ranking.
- `moult deadcode` — confidence-graded unused-method/constant candidates over a
  rubydex definition graph, with Rails entrypoint awareness; `--coverage` merges
  runtime evidence.
- `moult coverage` — per-symbol hot/cold/untracked map from a coverage file.
- `moult duplication` — flay-backed structural-clone groups.
- `moult boundaries` — packwerk architecture-boundary violations.
- `moult flags` — OpenFeature feature-flag usage; `--provider` adds local
  staleness candidates.
- `moult health` — composite, confidence-graded health score.
- `moult gate` — diff-aware PR risk gate (the only verdict layer).

[Unreleased]: https://github.com/moult-rb/moult-rb/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/moult-rb/moult-rb/releases/tag/v0.1.0
