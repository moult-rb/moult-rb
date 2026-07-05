# frozen_string_literal: true

require "test_helper"

# End-to-end test of the dead-code orchestration, driven by a fake Index so it
# runs without the native rubydex gem. Real fixture files on disk back the
# dynamic-dispatch scan and the Rails DSL scan; the fake index supplies the
# definitions and their reference data.
class TestDeadCode < Minitest::Test
  ROOT = File.expand_path("fixtures/deadcode", __dir__)
  FILES = Dir[File.join(ROOT, "**", "*.rb")].sort

  # Stands in for {Moult::Index}: returns hand-built definitions.
  FakeIndex = Struct.new(:definitions) do
    def resolved? = true

    def diagnostics = []
  end

  def defn(name:, path:, unqualified:, kind: :method, visibility: :public, refs: [], ref_count: nil,
    override_of: nil, hierarchy_refs: nil)
    Moult::Index::Definition.new(
      symbol_id: "#{path}:1:#{name}", kind: kind, name: name, unqualified_name: unqualified,
      owner: name.split(/[#.]/).first, visibility: visibility,
      singleton: !name.include?("#"),
      span: Moult::Span.new(start_line: 1, start_column: 0, end_line: 2, end_column: 3),
      path: path, reference_count: ref_count || refs.size, reference_paths: refs,
      override_of: override_of, owner_hierarchy_reference_paths: hierarchy_refs
    )
  end

  def definitions
    [
      defn(name: "Calculator#used_add", path: "plain.rb", unqualified: "used_add", refs: ["plain.rb"]),
      defn(name: "Calculator#unused_subtract", path: "plain.rb", unqualified: "unused_subtract"),
      defn(name: "Calculator#only_tested", path: "plain.rb", unqualified: "only_tested", refs: ["test/calculator_test.rb"], ref_count: 1),
      defn(name: "Calculator#dead_helper", path: "plain.rb", unqualified: "dead_helper", visibility: :private),
      defn(name: "Dispatcher#dynamic_target", path: "metaprogrammed.rb", unqualified: "dynamic_target"),
      defn(name: "UsersController#index", path: "app/controllers/users_controller.rb", unqualified: "index"),
      defn(name: "UsersController#authenticate", path: "app/controllers/users_controller.rb", unqualified: "authenticate", visibility: :private),
      defn(name: "UsersController#truly_dead", path: "app/controllers/users_controller.rb", unqualified: "truly_dead", visibility: :private),
      defn(name: "EmailJob#perform", path: "app/jobs/email_job.rb", unqualified: "perform"),
      defn(name: "Calculator#to_s", path: "plain.rb", unqualified: "to_s", override_of: "Object#to_s"),
      # Ancestor-liveness fixtures: a production-referenced base, a test-only
      # one, and an override pointing at each.
      defn(name: "LiveBase", path: "plain.rb", unqualified: "LiveBase", kind: :constant, refs: ["plain.rb"]),
      defn(name: "DeadBase", path: "plain.rb", unqualified: "DeadBase", kind: :constant, refs: ["test/base_test.rb"], ref_count: 1),
      defn(name: "Widget#render", path: "plain.rb", unqualified: "render", override_of: "LiveBase"),
      defn(name: "Relic#render", path: "plain.rb", unqualified: "render", override_of: "DeadBase"),
      # Hierarchy-reachability fixtures: an unreferenced tree, a referenced
      # one, and one referenced only from tests.
      defn(name: "Orphan#run", path: "plain.rb", unqualified: "run", hierarchy_refs: []),
      defn(name: "Reached#run", path: "plain.rb", unqualified: "run", hierarchy_refs: ["app/x.rb"]),
      defn(name: "TestReached#run", path: "plain.rb", unqualified: "run", hierarchy_refs: ["test/x_test.rb"])
    ]
  end

  def report
    @report ||= Moult::DeadCode.build_report(
      root: ROOT,
      files: FILES,
      index: FakeIndex.new(definitions: definitions),
      rails: Moult::RailsConventions.build(root: ROOT, files: FILES)
    )
  end

  def finding(name)
    report.findings.find { |f| f.name == name }
  end

  def rules_of(name)
    finding(name)&.reasons&.map(&:rule) || []
  end

  def test_referenced_method_is_not_a_finding
    assert_nil finding("Calculator#used_add"), "a production-referenced method is not dead"
  end

  def test_dead_private_method_scores_high
    f = finding("Calculator#dead_helper")
    refute_nil f
    assert_in_delta 0.85, f.confidence, 0.001
    assert_includes rules_of("Calculator#dead_helper"), :private_unused
  end

  def test_truly_dead_controller_method_survives_rails_suppression
    # The critical assertion: a genuinely-dead private controller method is not
    # silenced by Rails awareness.
    f = finding("UsersController#truly_dead")
    refute_nil f, "a genuinely dead controller method must still surface"
    assert_in_delta 0.85, f.confidence, 0.001
    refute_includes rules_of("UsersController#truly_dead"), :rails_entrypoint
  end

  def test_callback_symbol_method_lowered_but_present
    f = finding("UsersController#authenticate")
    refute_nil f, "metaprogramming/conventions lower confidence, never hide"
    assert_includes rules_of("UsersController#authenticate"), :rails_entrypoint
    assert_operator f.confidence, :<, finding("UsersController#truly_dead").confidence
  end

  def test_public_controller_action_lowered
    f = finding("UsersController#index")
    refute_nil f
    assert_includes rules_of("UsersController#index"), :rails_entrypoint
    detail = f.reasons.find { |r| r.rule == :rails_entrypoint }.detail
    assert_includes detail, "action"
  end

  def test_job_perform_lowered
    assert_includes rules_of("EmailJob#perform"), :rails_entrypoint
  end

  def test_metaprogramming_lowers_but_keeps_finding
    f = finding("Dispatcher#dynamic_target")
    refute_nil f
    assert_includes rules_of("Dispatcher#dynamic_target"), :dynamic_dispatch_present
  end

  def test_override_lowered_but_kept
    f = finding("Calculator#to_s")
    refute_nil f, "an override is reachable via the ancestor, but still a candidate"
    # Object is not indexed in-workspace: liveness unknown, conservative rule.
    assert_includes rules_of("Calculator#to_s"), :overrides_ancestor
  end

  def test_override_of_live_ancestor_takes_the_full_brake
    assert_includes rules_of("Widget#render"), :overrides_ancestor
    refute_includes rules_of("Widget#render"), :overrides_unreferenced_ancestor
  end

  def test_override_of_test_only_ancestor_takes_the_mild_brake
    assert_includes rules_of("Relic#render"), :overrides_unreferenced_ancestor
    refute_includes rules_of("Relic#render"), :overrides_ancestor
    assert_operator finding("Relic#render").confidence, :>, finding("Widget#render").confidence
  end

  def test_unreferenced_hierarchy_raises_confidence
    assert_includes rules_of("Orphan#run"), :unreferenced_hierarchy
    refute_includes rules_of("Reached#run"), :unreferenced_hierarchy
    assert_operator finding("Orphan#run").confidence, :>, finding("Reached#run").confidence
  end

  def test_hierarchy_referenced_only_from_tests_still_counts_as_dead_tree
    assert_includes rules_of("TestReached#run"), :unreferenced_hierarchy
  end

  def test_unknown_hierarchy_fires_no_tree_rule
    # Definitions without the index-computed field (nil) stay neutral.
    refute_includes rules_of("Calculator#dead_helper"), :unreferenced_hierarchy
  end

  def test_test_only_reference_is_a_weaker_candidate
    f = finding("Calculator#only_tested")
    refute_nil f
    assert_includes rules_of("Calculator#only_tested"), :has_test_only_references
  end

  def test_findings_sorted_by_confidence_desc
    confidences = report.findings.map(&:confidence)
    assert_equal confidences.sort.reverse, confidences
  end

  def test_min_confidence_filters
    filtered = Moult::DeadCode.build_report(
      root: ROOT, files: FILES,
      index: FakeIndex.new(definitions: definitions),
      rails: Moult::RailsConventions.build(root: ROOT, files: FILES),
      min_confidence: 0.5
    )
    assert(filtered.findings.all? { |f| f.confidence >= 0.5 })
    assert(filtered.findings.map(&:name).include?("Calculator#dead_helper"))
    refute(filtered.findings.map(&:name).include?("UsersController#index"))
  end

  def test_report_carries_rails_and_backend_metadata
    assert report.rails, "fixtures are a Rails app (config/application.rb present)"
    assert_equal "rubydex", report.backend
    assert report.resolved
  end

  # ---- runtime coverage merge (Phase 3) -------------------------------------

  # All FakeIndex spans are lines 1..2, so line 2 is the single body line. A
  # dataset value of >0 at index 1 is a hot body; 0 is cold; an absent file is
  # untracked. Joined on the same path the symbol_id carries.
  def merged_report(entries)
    dataset = Moult::Coverage::Dataset.new(
      entries: entries,
      source: Moult::Coverage::Source.new(backend: "coverage", version: "3.3.0", collected_at: "2026-06-29T11:00:00Z"),
      unmatched_count: 0
    )
    Moult::DeadCode.build_report(
      root: ROOT, files: FILES,
      index: FakeIndex.new(definitions: definitions),
      rails: Moult::RailsConventions.build(root: ROOT, files: FILES),
      coverage: dataset
    )
  end

  def test_runtime_hot_rescues_a_static_candidate
    report = merged_report("plain.rb" => [nil, 7])
    f = report.findings.find { |x| x.name == "Calculator#dead_helper" }
    refute_nil f
    assert_equal :hot, f.runtime
    assert_operator f.confidence, :<=, 0.1, "an executed method is rescued"
    assert_includes f.reasons.map(&:rule), :runtime_hot
  end

  def test_runtime_cold_corroborates_a_static_candidate
    report = merged_report("app/controllers/users_controller.rb" => [nil, 0])
    f = report.findings.find { |x| x.name == "UsersController#truly_dead" }
    refute_nil f
    assert_equal :cold, f.runtime
    assert_includes f.reasons.map(&:rule), :runtime_cold
    # Higher than the same finding scores statically (0.85).
    assert_operator f.confidence, :>, 0.85
  end

  def test_file_absent_from_coverage_is_untracked_and_unchanged
    report = merged_report("plain.rb" => [nil, 7])
    # metaprogrammed.rb is not in the dataset.
    f = report.findings.find { |x| x.name == "Dispatcher#dynamic_target" }
    refute_nil f
    assert_equal :untracked, f.runtime
    refute_includes f.reasons.map(&:rule), :runtime_cold
    refute_includes f.reasons.map(&:rule), :runtime_hot
  end

  def test_merge_records_coverage_source_on_report
    report = merged_report("plain.rb" => [nil, 7])
    assert_equal "coverage", report.coverage_source.backend
  end
end
