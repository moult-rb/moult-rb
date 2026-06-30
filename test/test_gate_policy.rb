# frozen_string_literal: true

require_relative "test_helper"

# Pins the gate's policy thresholds and the pure verdict engine against hand-built
# observations — like ABC, the coverage resolver, duplication confidence, boundaries
# severity and flags classification. Drift is a bug. Covers each rule's pass/fail
# boundary, verdict aggregation, the skipped-analysis contract, config overrides,
# and the humility wording invariant.
class TestGatePolicy < Minitest::Test
  E = Moult::Gate::Evaluation
  P = Moult::Gate::Policy

  def evaluate(observations)
    E.evaluate(observations: observations, policy: P.default)
  end

  def obs(**kwargs)
    E::Observations.new(**kwargs)
  end

  def rule(verdict, name)
    verdict.rules.find { |r| r.rule == name }
  end

  # ---- the defaults are pinned ----------------------------------------------

  def test_default_thresholds_are_pinned
    assert_equal 0.8, P::DEFAULTS[:dead_code_max_confidence]
    assert_equal "medium", P::DEFAULTS[:boundary_max_severity]
    assert_equal 30.0, P::DEFAULTS[:complexity_ceiling]
    assert_equal 100, P::DEFAULTS[:duplication_max_mass]
    assert_equal %w[test spec], P::DEFAULTS[:exclude_paths]
    assert_equal "default", P.default.source
  end

  def test_excluded_paths_cover_test_and_spec_trees
    policy = P.default
    assert policy.excluded?("test/test_foo.rb")
    assert policy.excluded?("spec/foo_spec.rb")
    refute policy.excluded?("lib/moult/foo.rb")
    refute policy.excluded?("app/models/user.rb")
  end

  # ---- dead-code rule boundary ----------------------------------------------

  def test_dead_code_at_threshold_fails
    v = evaluate(obs(dead_code: [E::DeadCodeObs.new(symbol_id: "a.rb:1:A#m", path: "a.rb", line: 1, confidence: 0.8)]))
    assert_equal "fail", v.verdict
    assert_equal false, rule(v, "no_new_dead_code").passed
  end

  def test_dead_code_below_threshold_passes
    v = evaluate(obs(dead_code: [E::DeadCodeObs.new(symbol_id: "a.rb:1:A#m", path: "a.rb", line: 1, confidence: 0.79)]))
    assert_equal "pass", v.verdict
    assert_equal true, rule(v, "no_new_dead_code").passed
  end

  def test_dead_code_observed_is_the_worst_confidence
    v = evaluate(obs(dead_code: [
      E::DeadCodeObs.new(symbol_id: "a.rb:1:A#m", path: "a.rb", line: 1, confidence: 0.5),
      E::DeadCodeObs.new(symbol_id: "a.rb:2:A#n", path: "a.rb", line: 2, confidence: 0.7)
    ]))
    assert_in_delta 0.7, rule(v, "no_new_dead_code").observed, 0.0001
    assert_empty rule(v, "no_new_dead_code").findings, "neither reaches 0.8"
  end

  # ---- boundary rule boundary -----------------------------------------------

  def test_high_severity_boundary_fails_medium_threshold
    v = evaluate(obs(boundaries: [E::BoundaryObs.new(symbol_id: nil, path: "p.rb", line: nil, severity: "high", violation_type: "dependency")]))
    assert_equal false, rule(v, "no_new_high_severity_boundary").passed
    assert_equal "high", rule(v, "no_new_high_severity_boundary").observed
  end

  def test_medium_severity_boundary_passes_medium_threshold
    v = evaluate(obs(boundaries: [E::BoundaryObs.new(symbol_id: nil, path: "p.rb", line: nil, severity: "medium", violation_type: "privacy")]))
    assert_equal true, rule(v, "no_new_high_severity_boundary").passed
  end

  # ---- complexity rule boundary ---------------------------------------------

  def test_complexity_at_ceiling_passes_just_over_fails
    at = evaluate(obs(complexity: [E::ComplexityObs.new(symbol_id: "a.rb:1:A#m", path: "a.rb", line: 1, abc: 30.0)]))
    assert_equal true, rule(at, "new_code_complexity_ceiling").passed, "at ceiling is allowed"
    over = evaluate(obs(complexity: [E::ComplexityObs.new(symbol_id: "a.rb:1:A#m", path: "a.rb", line: 1, abc: 30.1)]))
    assert_equal false, rule(over, "new_code_complexity_ceiling").passed
  end

  # ---- duplication rule boundary --------------------------------------------

  def test_duplication_at_mass_passes_just_over_fails
    at = evaluate(obs(duplication: [E::DuplicationObs.new(symbol_id: nil, path: "a.rb", line: 3, mass: 100)]))
    assert_equal true, rule(at, "new_code_duplication_ceiling").passed
    over = evaluate(obs(duplication: [E::DuplicationObs.new(symbol_id: nil, path: "a.rb", line: 3, mass: 101)]))
    assert_equal false, rule(over, "new_code_duplication_ceiling").passed
  end

  # ---- verdict aggregation ---------------------------------------------------

  def test_empty_observations_pass
    v = evaluate(obs(dead_code: [], boundaries: [], complexity: [], duplication: []))
    assert_equal "pass", v.verdict
    assert(v.rules.all? { |r| r.evaluated })
  end

  def test_any_failed_rule_fails_the_verdict
    v = evaluate(obs(
      dead_code: [],
      complexity: [E::ComplexityObs.new(symbol_id: "a.rb:1:A#m", path: "a.rb", line: 1, abc: 99.0)],
      duplication: [], boundaries: []
    ))
    assert_equal "fail", v.verdict
    assert_equal 1, v.reasons.size
  end

  # ---- skipped analysis ------------------------------------------------------

  def test_nil_observation_marks_rule_unevaluated_and_never_fails
    v = evaluate(obs(dead_code: nil, complexity: [], duplication: [], boundaries: nil,
      diagnostics: {dead_code: "rubydex blew up", boundaries: "not a packwerk project"}))
    dc = rule(v, "no_new_dead_code")
    refute dc.evaluated
    assert_nil dc.passed
    assert_equal "rubydex blew up", dc.reasons.first.detail
    assert_equal "pass", v.verdict, "a skipped analysis is a tool concern, not a gate failure"
  end

  # ---- config overrides ------------------------------------------------------

  def test_policy_load_overrides_only_known_keys_and_records_source
    policy = P.load({"complexity_ceiling" => 10, "bogus" => 1}, source: ".moult.yml")
    assert_equal 10, policy.complexity_ceiling
    assert_equal 0.8, policy.dead_code_max_confidence, "unset keys keep the default"
    assert_equal ".moult.yml", policy.source
    refute policy.respond_to?(:bogus)
  end

  def test_overridden_ceiling_changes_the_outcome
    strict = P.load({"complexity_ceiling" => 5}, source: "test")
    v = E.evaluate(
      observations: obs(complexity: [E::ComplexityObs.new(symbol_id: "a.rb:1:A#m", path: "a.rb", line: 1, abc: 6.0)]),
      policy: strict
    )
    assert_equal "fail", v.verdict
  end

  # ---- humility invariant ----------------------------------------------------

  def test_no_reason_or_detail_claims_certainty
    v = evaluate(obs(
      dead_code: [E::DeadCodeObs.new(symbol_id: "a.rb:1:A#m", path: "a.rb", line: 1, confidence: 0.95)],
      complexity: [], duplication: [], boundaries: []
    ))
    text = (v.reasons + v.rules.flat_map(&:reasons)).map(&:detail).join(" ").downcase
    refute_includes text, "certain"
    refute_includes text, "definitely"
    refute_includes text, "proven"
  end
end
