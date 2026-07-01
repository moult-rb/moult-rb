# Moult

Codebase intelligence for Ruby and Rails. Moult sheds dead code.

## moult-action (GitHub Action)

Add the gate to your CI and upload results to Moult Cloud:

```yaml
- uses: moult-rb/moult-rb@v0.1.0
  with:
    base-sha: ${{ github.event.pull_request.base.sha }}
    moult-cloud-url: https://moultrb.com
```

The action runs `bundle exec moult gate`, so the repository it runs in must have
`moult-rb` in its `Gemfile` (see [Install](#install)). Your workflow also needs
`permissions: id-token: write` for OIDC authentication.

Three commands today:

- **`moult hotspots`** ranks files by a **complexity × churn** score —
  the code that is both hard to understand *and* changed often.
- **`moult deadcode`** lists **confidence-graded dead-code candidates** —
  unused methods and constants, over a real definition/reference graph, with
  Rails entrypoint awareness so framework-invoked code isn't a false positive.
  Feed it a coverage file with `--coverage` and runtime evidence is merged into
  every finding's confidence (see [Runtime coverage](#runtime-coverage)).
- **`moult coverage`** resolves a coverage file to a per-symbol
  **hot / cold / untracked** map.

Parsing is [Prism](https://github.com/ruby/prism); the definition/reference
index behind `deadcode` is [rubydex](https://github.com/Shopify/rubydex).

> Every finding Moult produces is a confidence-graded signal, never a claim of
> fact. In Ruby, dead code can almost never be *proven* statically
> (metaprogramming, `send`, `method_missing`, Zeitwerk, dynamic dispatch), so
> Moult never asserts that code is certainly dead — it attaches a confidence and
> the reasons behind it. Runtime coverage is the missing signal: it raises
> confidence on code that never ran and **rescues** candidates that did. Later
> phases add duplication analysis behind the same typed JSON contract.

## Install

Add to your Gemfile:

```ruby
gem "moult-rb"
```

Or install directly:

```sh
gem install moult-rb
```

The gem is published as `moult-rb`; the command and library are still `moult`
(`require "moult"`, `moult hotspots`, …). Requires Ruby 3.3+.

## Usage

```sh
moult hotspots [PATH] [options]
```

`PATH` defaults to the current directory. Inside a git repository Moult
analyses the files git tracks (respecting `.gitignore`); elsewhere it globs for
`*.rb`, skipping `vendor/`, `tmp/`, and `node_modules/`.

### Example

```
$ moult hotspots

Hotspots (complexity x churn): 3 files — churn over last 12 months

#  SCORE  COMPLEXITY  CHURN  FILE                    WORST METHOD
1   95.2        15.9      6  app/services/charge.rb  Charge#call (15.9)
2   59.6        19.9      3  app/models/user.rb      User#eligible? (15.9)
3    3.0         3.0      1  lib/util.rb             Util.blank? (3.0)
```

`app/models/user.rb` is the most *complex* file, but `app/services/charge.rb`
tops the list because it changes twice as often — complexity alone would have
missed it.

### JSON

`--format json` emits the typed contract (see
[`schema/hotspots.schema.json`](schema/hotspots.schema.json)), suitable for CI
and tooling:

```sh
moult hotspots --format json
```

```json
{
  "schema_version": 1,
  "tool": { "name": "moult", "version": "0.1.0" },
  "analysis": {
    "root": "/path/to/project",
    "git_ref": "c6e23f6f5d1003ea3cbc874aea5f1c55bf80a740",
    "generated_at": "2026-06-29T06:03:22Z",
    "churn": { "window": "last 12 months", "since": null }
  },
  "hotspots": [
    {
      "path": "app/services/charge.rb",
      "score": 95.22,
      "complexity": 15.87,
      "churn": 6,
      "confidence": null,
      "category": null,
      "methods": [
        {
          "symbol_id": "app/services/charge.rb:2:Charge#call",
          "name": "Charge#call",
          "span": { "start_line": 2, "start_column": 2, "end_line": 15, "end_column": 5 },
          "abc": 15.87,
          "confidence": null,
          "category": null
        }
      ]
    }
  ]
}
```

`confidence` and `category` are reserved for later phases and are always `null`
today — Moult never asserts that code is dead.

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--format table\|json` | `table` | Output format. |
| `--limit N` | `20` | Show the top N hotspots. `0` shows all. |
| `--since DATE` | `12 months ago` | Churn window start; any value `git log --since` accepts (e.g. `2025-01-01`). |
| `--quiet` | off | Suppress informational notes on stderr. |

Moult is report-only: it exits `0` on success and non-zero only on error. There
are no failing thresholds.

## Dead code

```sh
moult deadcode [PATH] [options]
```

Lists methods and constants with no resolvable reference, each as a
**confidence-graded candidate** — never an assertion that the code is dead. The
definition/reference graph comes from [rubydex](https://github.com/Shopify/rubydex)
(the engine behind ruby-lsp); the confidence and its reasons come from Moult.

```
$ moult deadcode

Dead-code candidates (confidence-graded — not certainties): 3 findings

CONF  KIND    SYMBOL              LOCATION              TOP REASON
0.85  method  Report#legacy_to_h  lib/report.rb:42      private method with no caller in the codebase
0.30  method  Api#export          lib/api.rb:8          public method may be an external API entrypoint
0.00  method  UsersController#index  app/controllers/users_controller.rb:5  Rails framework entrypoint: public action in app/controllers/users_controller.rb
```

A private method with no caller scores high; a public method (a likely API
surface) scores lower; a routed controller action sinks to the bottom — but
**still appears**. Moult lowers confidence for framework conventions and
metaprogramming, it never silently hides a candidate.

### How confidence is computed

Each finding starts from a base score (by kind and visibility) and is adjusted
by a set of named rules, every one recorded as a `reason`:

- **Raises** confidence: a private method with no caller; a `@deprecated` mark.
- **Lowers** confidence: a public method (API surface); references only from
  tests; a constructor (`initialize`, invoked implicitly by `.new`); a method
  that **overrides or implements an ancestor's method** (reachable via that
  interface — polymorphic dispatch); a file that uses
  `send`/`define_method`/`method_missing`/`const_get`/`eval`.
- **Lowers strongly**: a Rails entrypoint — controller/mailer actions, helpers,
  job `#perform`, `before_action :symbol`-style callbacks, serializers,
  initializers. Rails awareness is on automatically when a Rails app is detected
  (`--no-rails` to disable).

### Dead-code JSON

`--format json` emits the typed contract (see
[`schema/deadcode.schema.json`](schema/deadcode.schema.json)):

```json
{
  "schema_version": 2,
  "tool": { "name": "moult", "version": "0.1.0" },
  "analysis": {
    "root": "/path/to/project",
    "git_ref": "c6e23f6f…",
    "generated_at": "2026-06-29T06:03:22Z",
    "coverage": null,
    "index": { "backend": "rubydex", "backend_version": "0.2.6", "resolved": true, "rails": true, "diagnostics": [] }
  },
  "findings": [
    {
      "symbol_id": "lib/report.rb:42:Report#legacy_to_h",
      "kind": "method",
      "name": "Report#legacy_to_h",
      "span": { "start_line": 42, "start_column": 2, "end_line": 50, "end_column": 5 },
      "confidence": 0.85,
      "category": "dead_code",
      "runtime": null,
      "reasons": [
        { "rule": "base_score", "delta": 0.75, "detail": "base for method/private" },
        { "rule": "private_unused", "delta": 0.1, "detail": "private method with no caller in the codebase" }
      ]
    }
  ]
}
```

`analysis.coverage` and each finding's `runtime` are `null` until you pass
`--coverage` (see below). The `symbol_id` is the same `"<path>:<line>:<name>"`
join key the hotspots contract uses, so the analyses — and the coverage merge —
line up.

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--format table\|json` | `table` | Output format. |
| `--min-confidence N` | `0.0` | Hide findings below this confidence (`0`–`1`). |
| `--[no-]rails` | on | Apply Rails entrypoint awareness. |
| `--coverage PATH` | off | Merge a local coverage file as runtime evidence. |
| `--coverage-format FMT` | `auto` | `auto`, `simplecov`, or `coverage`. |
| `--quiet` | off | Suppress informational notes on stderr. |

Currently in scope: unused **methods** and non-class **constants**. Classes and
modules are not flagged (this sidesteps Zeitwerk/STI false positives). Route-file
and view-template resolution are deferred to a later slice.

## Runtime coverage

Static analysis can never *prove* Ruby dead code — `send`, `method_missing`,
metaprogramming and Zeitwerk all defeat it. Production coverage is the missing
signal, and Moult merges it **both ways**:

- a candidate whose body **never ran** (runtime-cold) gets its confidence
  *raised* — corroboration that it really is dead;
- a candidate that **did run** (runtime-hot) is *rescued* — its confidence is
  capped low, because it's the false positive static analysis missed.

Point `--coverage` at a local coverage file — either SimpleCov's
`coverage/.resultset.json` or a JSON dump of stdlib
[`Coverage.result`](https://docs.ruby-lang.org/en/master/Coverage.html). The
format is auto-detected.

```sh
moult deadcode --coverage coverage/.resultset.json
```

```
Dead-code candidates (confidence-graded — not certainties): 3 findings

CONF  KIND    RUNTIME  SYMBOL              LOCATION          TOP REASON
0.95  method  cold     Report#legacy_to_h  lib/report.rb:42  never executed in the supplied coverage run (runtime-cold corroborates)
0.10  method  hot      Api#dispatch        lib/api.rb:8      executed at runtime (coverage) despite no static reference; rescued
```

To produce a stdlib dump without SimpleCov, capture coverage around your test run
and write the result:

```ruby
require "coverage"
Coverage.start(lines: true)
# ...load and exercise your app / run your tests...
File.write("coverage.json", JSON.generate(Coverage.result))
```

Coverage is keyed by line; Moult resolves it to each symbol's definition span,
counting only the **method body** (the `def` line is counted at load time, not
per call, so it's excluded). A symbol is **hot** if any executable body line ran,
**cold** if the file is tracked but none did, and **untracked** when there's no
signal (the file isn't in the dataset, or it's a constant). Coverage is evidence,
never proof — runtime-cold raises confidence, it never asserts certain death.

### Coverage map

`moult coverage` is the standalone view of the same classification — a typed
hot/cold/untracked map over every definition (see
[`schema/coverage.schema.json`](schema/coverage.schema.json)):

```sh
moult coverage --coverage coverage/.resultset.json            # table
moult coverage --coverage coverage/.resultset.json --format json
```

```
Runtime coverage map: 128 hot, 14 cold, 9 untracked

RUNTIME  KIND    SYMBOL              LOCATION
hot      method  Charge#call         app/services/charge.rb:2
cold     method  Report#legacy_to_h  lib/report.rb:42
```

## How the score works

- **Complexity** — a flog-style weighted ABC score per method: assignments,
  branches (every method call, including operators), and conditions, with
  metaprogramming calls penalised and a compounding penalty for nesting depth.
  A file's complexity is the sum of its methods'.
- **Churn** — the number of commits that touched the file within the window
  (default: the last 12 months). Renames are not followed.
- **Score** — `complexity × churn`, ranked descending.

Outside a git repository churn is `0`, so files rank by complexity alone.

## Open source & Moult Cloud

The `moult` gem — the CLI and every analysis in it — is free and open source
under [Apache-2.0](LICENSE.txt). **Moult Cloud** is a separate commercial
product: a hosted GitHub App that turns `moult gate` into an enforced,
team-visible PR check with history, trends, and dashboards. The gem stands on
its own; the cloud is optional.

## Contributing

Contributions welcome — see [CONTRIBUTING](CONTRIBUTING.md), our
[Code of Conduct](CODE_OF_CONDUCT.md), and [SECURITY](SECURITY.md) for reporting
vulnerabilities. Changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## License

[Apache-2.0](LICENSE.txt). © 2026 The Moult authors. See [NOTICE](NOTICE).
