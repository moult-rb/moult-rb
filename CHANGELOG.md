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
- `clone_group` on duplication findings and gate contributions — a
  `"<kind>:<structural-hash>"` join key (kind `identical`|`similar`) shared by
  every occurrence of a clone group, so consumers can link exact twins. Null on
  non-duplication contributions. Additive/optional in both schemas, so
  `schema_version` stays 1.

### Changed
- The gate now emits one duplication contribution per in-diff occurrence
  (previously one per clone group, attributed to its first in-diff
  occurrence), so every site of a clone is visible downstream. Verdicts are
  unchanged, and rule reasons still count clone groups.

## [0.3.0] - 2026-07-02

(v0.2.0 was tagged in git but never published as a gem — its changes are
included here.)

### Added
- `Moult::CloudUpload.projection` — the sanitised payload builder for the
  `moult-action` → Moult Cloud upload (allow-lists top-level keys; normalises
  the absolute `analysis.root` path; the gate report is already source-free).
- `action.yml` — the `moult-action` composite GitHub Action: runs the gate in
  CI and uploads the projected result with keyless GitHub OIDC auth.
- Open-source release setup: Apache-2.0 license, Trusted Publishing release
  workflow, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`.
- `.ruby-version` (3.3), read by `ruby/setup-ruby` in CI and in the action.

### Changed
- License changed from MIT to **Apache-2.0** (adds an explicit patent grant;
  the chosen open-core core license).
- `moult-action` installs moult from the action checkout instead of running
  `bundle exec` against the caller's bundle — consuming repos no longer need
  moult in their Gemfile (or a Gemfile at all).
- `moult-action`'s `moult-cloud-url` input now defaults to
  `https://moultrb.com`, so a bare `- uses: moult-rb/moult-rb@v1` step works
  with no `with:` block; the input remains overridable for self-hosted
  instances.
- Release workflow only triggers on full-semver tags (`vX.Y.Z`), so the
  floating `v1` major tag can be re-pointed without triggering a gem publish.
- The gem publishes as `moult` again (reverting the brief `moult-rb` rename):
  `moult` 0.1.0 is already the published package, and `gem install moult`
  should keep resolving to current releases. The repository and action stay
  `moult-rb/moult-rb`.

### Fixed
- `moult-action` fails with an actionable message — instead of a raw Ruby
  `KeyError` backtrace — when the workflow is missing
  `permissions: id-token: write`, and cleanly skips the upload (verdict still
  enforced) on pull requests from forks, which GitHub never grants an OIDC
  identity. Non-2xx responses from GitHub's token endpoint are now reported
  with their status and body.
- `moult-action`'s `base-sha` now defaults to the pull request's base branch
  (or the merge queue's base SHA), falling back to the repository's default
  branch — previously a hardcoded `origin/main` broke PR scans in any
  repository whose base branch isn't `main`.
- `moult-action` auto mode maps `merge_group` events to `pr` scans (diffed
  against the queue's base SHA) and rejects `pull_request_target`, which
  checks out the base branch and would silently gate an empty diff as a pass.

## [0.1.0] - 2026-06-30

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

[Unreleased]: https://github.com/moult-rb/moult-rb/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/moult-rb/moult-rb/compare/v0.1.0...v0.3.0
[0.1.0]: https://github.com/moult-rb/moult-rb/releases/tag/v0.1.0
