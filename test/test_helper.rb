# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "moult"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

module TestHelpers
  SCHEMA_DIR = File.expand_path("../schema", __dir__)
  SCHEMA_PATH = File.join(SCHEMA_DIR, "hotspots.schema.json")

  # ---- temp git repo helpers (shared by the integration, gate and diff tests) --

  # Make a throwaway git repo and yield its path; cleaned up afterwards.
  def in_git_repo
    Dir.mktmpdir do |dir|
      git(dir, "init", "--quiet")
      git(dir, "config", "user.email", "test@example.com")
      git(dir, "config", "user.name", "Test")
      yield dir
    end
  end

  # Build a repo, write +files+ (rel => contents), commit them as the base, and
  # yield (root, base_sha). The base for a gate/diff scope test.
  def committed_git_repo(files)
    in_git_repo do |root|
      files.each { |rel, contents| write_source(root, rel, contents) }
      git_commit(root, "base")
      yield root, git(root, "rev-parse", "HEAD").strip
    end
  end

  # Run git in +dir+, returning stdout; raises on failure (a broken test setup).
  def git(dir, *args)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?
    out
  end

  def write_source(dir, rel, contents)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  def git_commit(dir, message)
    git(dir, "add", "-A")
    git(dir, "commit", "--quiet", "-m", message)
  end

  # Absolute path to a file or directory under test/fixtures.
  def fixture_path(*parts)
    File.expand_path(File.join("fixtures", *parts), __dir__)
  end

  # Read a fixture file's contents.
  def fixture(*parts)
    File.read(fixture_path(*parts))
  end

  # A parsed schema file from schema/.
  def schema_json(name)
    require "json"
    JSON.parse(File.read(File.join(SCHEMA_DIR, name)))
  end

  # The hotspots JSON Schema, parsed.
  def hotspots_schema
    schema_json("hotspots.schema.json")
  end

  # A JSONSchemer for a schema file, resolving cross-file $refs (to
  # common.schema.json) against the local schema/ directory by basename.
  def schemer(name)
    require "json_schemer"
    JSONSchemer.schema(
      schema_json(name),
      ref_resolver: ->(uri) { schema_json(File.basename(uri.path)) }
    )
  end

  # A small, fully-populated Report for exercising serialization/formatting.
  def sample_report
    span = Moult::Span.new(start_line: 10, start_column: 2, end_line: 24, end_column: 5)
    method = Moult::Report::Method.new(
      symbol_id: "lib/foo.rb:10:Foo::Bar#baz",
      name: "Foo::Bar#baz",
      span: span,
      abc: 12.34
    )
    hotspot = Moult::Report::Hotspot.new(
      path: "lib/foo.rb",
      score: 37.02,
      complexity: 12.34,
      churn: 3,
      methods: [method]
    )
    Moult::Report.new(
      root: "/abs/project",
      hotspots: [hotspot],
      git_ref: "0123abc",
      generated_at: "2026-06-29T12:00:00Z",
      churn_window: "last 12 months",
      churn_since: "2025-06-29"
    )
  end

  # A Report with N synthetic hotspots, ranked highest-first.
  def report_with_n_hotspots(count)
    hotspots = Array.new(count) do |i|
      rank = count - i
      method = Moult::Report::Method.new(
        symbol_id: "f#{i}.rb:1:F#{i}#m",
        name: "F#{i}#m",
        span: Moult::Span.new(start_line: 1, start_column: 0, end_line: 2, end_column: 3),
        abc: rank.to_f
      )
      Moult::Report::Hotspot.new(
        path: "f#{i}.rb", score: rank.to_f, complexity: rank.to_f, churn: 1, methods: [method]
      )
    end
    Moult::Report.new(root: "/x", hotspots: hotspots)
  end

  # A small, fully-populated DeadCodeReport for serialization/schema tests.
  # Coverage-merged: the finding carries a runtime classification and the report
  # a coverage source, exercising the populated v2 runtime block.
  def sample_deadcode_report
    span = Moult::Span.new(start_line: 7, start_column: 2, end_line: 9, end_column: 5)
    finding = Moult::Confidence::Finding.new(
      symbol_id: "app/models/user.rb:7:User#stale",
      kind: :method,
      name: "User#stale",
      span: span,
      path: "app/models/user.rb",
      confidence: 0.85,
      category: "dead_code",
      runtime: :cold,
      reasons: [
        Moult::Confidence::Reason.new(rule: :base_score, delta: 0.75, detail: "base for method/private"),
        Moult::Confidence::Reason.new(rule: :private_unused, delta: 0.1, detail: "private method with no caller in the codebase"),
        Moult::Confidence::Reason.new(rule: :runtime_cold, delta: 0.2, detail: "never executed in the supplied coverage run (runtime-cold corroborates)")
      ]
    )
    Moult::DeadCodeReport.new(
      root: "/abs/project",
      findings: [finding],
      git_ref: "0123abc",
      generated_at: "2026-06-29T12:00:00Z",
      backend: "rubydex",
      backend_version: "0.2.6",
      resolved: true,
      rails: true,
      diagnostics: [],
      coverage_source: Moult::Coverage::Source.new(
        backend: "simplecov", version: nil, collected_at: "2026-06-29T11:00:00Z"
      )
    )
  end

  # A DeadCodeReport with N synthetic findings, ranked highest-confidence first.
  def report_with_n_findings(count)
    findings = Array.new(count) do |i|
      confidence = ((count - i) / count.to_f).round(2)
      Moult::Confidence::Finding.new(
        symbol_id: "f#{i}.rb:1:F#{i}#m",
        kind: :method,
        name: "F#{i}#m",
        span: Moult::Span.new(start_line: 1, start_column: 0, end_line: 2, end_column: 3),
        path: "f#{i}.rb",
        confidence: confidence,
        category: "dead_code",
        runtime: nil,
        reasons: [Moult::Confidence::Reason.new(rule: :base_score, delta: confidence, detail: "base")]
      )
    end
    Moult::DeadCodeReport.new(root: "/x", findings: findings)
  end

  # A small, fully-populated DuplicationReport for serialization/schema tests.
  # Exercises both kinds (identical/similar) and both occurrence shapes (an
  # attributed symbol_id and a null one for top-level code).
  def sample_duplication_report
    reason = ->(rule, delta, detail) { Moult::Duplication::Confidence::Reason.new(rule: rule, delta: delta, detail: detail) }
    occ = ->(symbol_id, path, line) { Moult::DuplicationReport::Occurrence.new(symbol_id: symbol_id, path: path, line: line, fuzzy: false) }

    identical = Moult::DuplicationReport::Finding.new(
      confidence: 0.78,
      kind: :identical,
      node_type: "defn",
      mass: 92,
      clone_group: "identical:190423",
      reasons: [
        reason.call(:base_score, 0.6, "identical structural match (byte-for-byte)"),
        reason.call(:medium_mass, 0.1, "moderate duplicated mass (92)"),
        reason.call(:whole_definition, 0.08, "duplicates a whole defn")
      ],
      occurrences: [
        occ.call("app/models/user.rb:7:User#normalize", "app/models/user.rb", 7),
        occ.call("app/models/account.rb:4:Account#normalize", "app/models/account.rb", 4)
      ]
    )
    similar = Moult::DuplicationReport::Finding.new(
      confidence: 0.45,
      kind: :similar,
      node_type: "call",
      mass: 34,
      clone_group: "similar:88231",
      reasons: [reason.call(:base_score, 0.45, "structurally-similar match (names/literals differ)")],
      occurrences: [
        occ.call(nil, "config/initializers/a.rb", 3),
        occ.call(nil, "config/initializers/b.rb", 3)
      ]
    )
    Moult::DuplicationReport.new(
      root: "/abs/project",
      findings: [identical, similar],
      git_ref: "0123abc",
      generated_at: "2026-06-29T12:00:00Z",
      backend: "flay",
      backend_version: "2.14.4",
      min_mass: 16,
      fuzzy: false
    )
  end

  # A small, fully-populated HealthReport for serialization/schema tests.
  # Exercises a present + absent component (coverage skipped), each component's
  # reasons, and per-file roll-ups carrying contributing symbol_ids.
  def sample_health_report
    reason = ->(rule, value, detail) { Moult::Health::Score::Reason.new(rule: rule, value: value, detail: detail) }
    component = ->(name, score, nw, summary, reasons) {
      Moult::HealthReport::ComponentView.new(
        name: name, category: name, present: true, score: score,
        weight: Moult::Health::Score::WEIGHTS.fetch(name), normalized_weight: nw,
        summary: summary, reasons: reasons, diagnostic: nil
      )
    }

    components = [
      component.call("complexity", 0.8, 0.4, {file_count: 10, mean_complexity: 24.0, churn_present: true},
        [reason.call(:complexity_churn_density, 0.8, "mean complexity*churn per file 60.0 vs knee 300.0")]),
      component.call("dead_code", 0.9, 0.3333, {symbol_count: 120, candidate_count: 4, confidence_sum: 1.44, resolved: true},
        [reason.call(:dead_density, 0.9, "confidence-weighted dead density 0.012 vs knee 0.12 (4 candidates / 120 symbols)")]),
      component.call("duplication", 0.7, 0.2667, {file_count: 10, weighted_dup_mass: 12.0, clone_sets: 1},
        [reason.call(:duplication_burden, 0.7, "confidence-weighted duplicated mass per file 12.0 vs knee 40.0 (1 clone sets)")]),
      Moult::HealthReport::ComponentView.new(
        name: "coverage", category: nil, present: false, score: nil,
        weight: Moult::Health::Score::WEIGHTS.fetch("coverage"), normalized_weight: nil,
        summary: {}, reasons: [], diagnostic: "no --coverage supplied"
      )
    ]

    files = [
      Moult::HealthReport::FileView.new(
        path: "app/models/user.rb", score: 0.62, grade: "D",
        components: {"complexity" => 0.55, "dead_code" => 0.8, "duplication" => 0.5},
        symbol_ids: ["app/models/user.rb:7:User#stale", "app/models/user.rb:12:User#normalize"],
        symbol_count: 2
      ),
      Moult::HealthReport::FileView.new(
        path: "app/services/report.rb", score: 0.88, grade: "B",
        components: {"complexity" => 0.88},
        symbol_ids: ["app/services/report.rb:3:Report#run"], symbol_count: 1
      )
    ]

    Moult::HealthReport.new(
      root: "/abs/project",
      score: 0.81,
      grade: "B",
      components: components,
      files: files,
      git_ref: "0123abc",
      generated_at: "2026-06-29T12:00:00Z",
      churn_window: "last 12 months",
      churn_since: nil
    )
  end

  # A small, fully-populated BoundariesReport for serialization/schema tests.
  # Exercises both a high (dependency) and a medium (privacy) finding, a
  # multi-occurrence group, and the null (file-keyed) symbol_id.
  def sample_boundaries_report
    occ = ->(path) { Moult::BoundariesReport::Occurrence.new(symbol_id: nil, path: path) }
    finding = ->(type, sev, ref, defn, const, paths) {
      Moult::BoundariesReport::Finding.new(
        violation_type: type, severity: sev, referencing_package: ref,
        defining_package: defn, constant: const,
        reasons: Moult::Boundaries::Severity.classify(violation_type: type).reasons,
        occurrences: paths.map { |p| occ.call(p) }
      )
    }

    findings = [
      finding.call("dependency", "high", "packages/billing", "packages/user", "::User::Account",
        ["packages/billing/app/billing/invoice.rb", "packages/billing/app/billing/charge.rb"]),
      finding.call("privacy", "medium", "packages/web", "packages/user", "::User::Token",
        ["packages/web/app/web/dashboard.rb"])
    ]

    Moult::BoundariesReport.new(
      root: "/abs/project",
      findings: findings,
      git_ref: "0123abc",
      generated_at: "2026-06-29T12:00:00Z",
      backend: "packwerk",
      backend_version: "3.3.0",
      configured: true
    )
  end

  # A small, fully-populated FlagsReport for exercising serialization/contract.
  # One multi-site boolean flag (one in-method reference, one top-level) and one
  # single-site string flag, plus a dynamic (uncatalogued) reference.
  def sample_flags_report
    occ = ->(sym, path, line, method) {
      Moult::FlagsReport::Occurrence.new(symbol_id: sym, path: path, line: line, method_name: method)
    }
    finding = ->(key, types, defaults, occurrences) {
      a = Moult::Flags::Classification.classify(value_types: types, default_values: defaults)
      Moult::FlagsReport::Finding.new(
        flag_key: key, value_type: a.value_type, reference_count: a.reference_count,
        default_values: a.default_values, reasons: a.reasons, occurrences: occurrences
      )
    }

    findings = [
      finding.call("new_checkout", %w[boolean boolean], %w[false false], [
        occ.call("app/billing.rb:5:Billing#checkout", "app/billing.rb", 6, "fetch_boolean_value"),
        occ.call(nil, "config/initializers/flags.rb", 3, "fetch_boolean_value")
      ]),
      finding.call("checkout_label", %w[string], %w[Pay], [
        occ.call("app/billing.rb:5:Billing#checkout", "app/billing.rb", 8, "fetch_string_value")
      ])
    ]

    Moult::FlagsReport.new(
      root: "/abs/project",
      findings: findings,
      dynamic_references: 1,
      git_ref: "0123abc",
      generated_at: "2026-06-29T12:00:00Z"
    )
  end

  # A FlagsReport with a provider snapshot merged: the v2 shape. Each finding carries
  # a confidence-graded staleness candidate (the populated confidence slot) and the
  # report a provider provenance block. Exercises a rolled_out candidate and an absent
  # one (a code key the provider does not know).
  def sample_flags_staleness_report
    occ = ->(sym, path, line, method) {
      Moult::FlagsReport::Occurrence.new(symbol_id: sym, path: path, line: line, method_name: method)
    }
    finding = ->(key, types, defaults, occurrences, staleness) {
      a = Moult::Flags::Classification.classify(value_types: types, default_values: defaults)
      Moult::FlagsReport::Finding.new(
        flag_key: key, value_type: a.value_type, reference_count: a.reference_count,
        default_values: a.default_values, reasons: a.reasons, occurrences: occurrences,
        staleness: staleness
      )
    }
    state = ->(**kw) { Moult::Flags::Snapshot::FlagState.new(key: "k", default_variant: nil, updated_at: nil, archived: false, has_targeting: false, **kw) }

    findings = [
      finding.call("new_checkout", %w[boolean boolean], %w[false false], [
        occ.call("app/billing.rb:5:Billing#checkout", "app/billing.rb", 6, "fetch_boolean_value"),
        occ.call(nil, "config/initializers/flags.rb", 3, "fetch_boolean_value")
      ], Moult::Flags::Staleness.classify(state: state.call(enabled: true, has_targeting: false))),
      finding.call("checkout_label", %w[string], %w[Pay], [
        occ.call("app/billing.rb:5:Billing#checkout", "app/billing.rb", 8, "fetch_string_value")
      ], Moult::Flags::Staleness.classify(state: nil, has_dynamic_references: true))
    ]

    Moult::FlagsReport.new(
      root: "/abs/project",
      findings: findings,
      dynamic_references: 1,
      git_ref: "0123abc",
      generated_at: "2026-06-29T12:00:00Z",
      provider_source: Moult::Flags::Snapshot::Source.new(
        backend: "flagd", version: "42", exported_at: "2026-06-01T00:00:00Z"
      )
    )
  end

  # A small, fully-populated GateReport for serialization/schema tests. Exercises
  # a FAIL verdict with mixed rule outcomes: failed rules with contributing
  # findings (dead code; a two-occurrence clone group sharing a clone_group key),
  # a passed rule (complexity), a skipped rule (boundaries, non-packwerk repo),
  # plus a present + absent component view.
  def sample_gate_report
    e = Moult::Gate::Evaluation
    policy = Moult::Gate::Policy.default
    observations = e::Observations.new(
      dead_code: [e::DeadCodeObs.new(symbol_id: "app/models/user.rb:7:User#stale", path: "app/models/user.rb", line: 7, confidence: 0.85)],
      complexity: [e::ComplexityObs.new(symbol_id: "app/models/user.rb:12:User#normalize", path: "app/models/user.rb", line: 12, abc: 8.0)],
      duplication: [
        e::DuplicationObs.new(symbol_id: "app/models/user.rb:20:User#emit", path: "app/models/user.rb", line: 20, mass: 116, clone_group: "identical:190423"),
        e::DuplicationObs.new(symbol_id: "app/models/account.rb:9:Account#emit", path: "app/models/account.rb", line: 9, mass: 116, clone_group: "identical:190423")
      ],
      boundaries: nil,
      diagnostics: {boundaries: "not a packwerk project (no packwerk.yml)"}
    )
    evaluation = e.evaluate(observations: observations, policy: policy)

    components = [
      Moult::GateReport::Component.new(name: "complexity", present: true, diagnostic: nil),
      Moult::GateReport::Component.new(name: "dead_code", present: true, diagnostic: nil),
      Moult::GateReport::Component.new(name: "duplication", present: true, diagnostic: nil),
      Moult::GateReport::Component.new(name: "boundaries", present: false, diagnostic: "not a packwerk project (no packwerk.yml)")
    ]

    Moult::GateReport.new(
      root: "/abs/project",
      base_ref: "origin/main",
      merge_base: "0123abcdef",
      scope: :diff,
      components: components,
      policy: policy,
      evaluation: evaluation,
      git_ref: "0123abc",
      generated_at: "2026-06-29T12:00:00Z"
    )
  end
end

module Minitest
  class Test
    include TestHelpers
  end
end
