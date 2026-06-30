# Contributing to Moult

Thanks for your interest in improving Moult! This guide covers the essentials.

## What Moult is (and the free/paid boundary)

The **`moult` gem** (this repo) is free and open source under **Apache-2.0** —
the CLI and all of its analyses. **Moult Cloud** (the hosted GitHub App: PR
gating at scale, dashboards, history, teams) is a separate, commercial product.
Contributions here are to the open-source gem.

## Development setup

```sh
bundle install
bundle exec rake          # the default task: full Minitest suite + standardrb
```

Useful commands:

```sh
bundle exec rake test                                  # tests only
bundle exec ruby -Itest test/test_abc.rb               # one test file
bundle exec ruby -Itest test/test_abc.rb -n test_name  # one test by name
bundle exec standardrb                                 # lint
bundle exec standardrb --fix                           # autofix (safe fixes)
```

## Conventions

- **Tests:** [Minitest](https://github.com/minitest/minitest), written
  alongside the code. The JSON contracts (`schema/*.json`) and the
  confidence/scoring models are the things most worth covering — those models
  are **pinned**; treat drift as a bug, not a test to "fix."
- **Style:** [Standard](https://github.com/standardrb/standard) (`standardrb`).
- **TDD:** write the failing test first.
- **The two protected APIs** — the typed JSON output contract and the
  per-finding confidence model — are the public interface. Guard them; don't
  leak analysis internals through them.
- **The humility invariant:** never assert that code is *certainly* dead/stale.
  Every finding carries a `confidence` and its `reasons`.

## Pull requests

1. Open an issue first for anything non-trivial so we can agree on the approach.
2. Keep PRs focused; include tests; make sure `bundle exec rake` is green.
3. Write clear commit messages.

## Contributor License Agreement (CLA)

Moult is single-vendor open core. To keep dual-licensing/relicensing options
open, contributors will be asked to sign a CLA before their first contribution
is merged (a CLA-assistant check will be added to PRs). Until that is in place,
by submitting a contribution you agree it is licensed under the project's
Apache-2.0 license. (The CLA terms will be published in the repo; if you have
questions, ask in your PR.)

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you agree to uphold it.
