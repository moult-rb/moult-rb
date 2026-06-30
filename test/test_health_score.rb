# frozen_string_literal: true

require "test_helper"

# The health score model aggregates the other analyses into one composite signal.
# Like the ABC metric, the coverage resolver, and the duplication confidence model,
# its weighting and normalisation are pinned against hand-built inputs — drift is a
# bug. The function is pure (no IO, no report objects), so every component and the
# renormalisation are exercised in isolation.
class TestHealthScore < Minitest::Test
  S = Moult::Health::Score

  # ---- builders -------------------------------------------------------------

  def complexity(file_count: 1, total_complexity: 0.0, total_score: 0.0, churn_present: true)
    S::ComplexityInput.new(file_count: file_count, total_complexity: total_complexity,
      total_score: total_score, churn_present: churn_present)
  end

  def dead(symbol_count: 100, confidence_sum: 0.0, finding_count: 0, resolved: true)
    S::DeadCodeInput.new(symbol_count: symbol_count, confidence_sum: confidence_sum,
      finding_count: finding_count, resolved: resolved)
  end

  def dup(file_count: 1, weighted_dup_mass: 0.0, set_count: 0)
    S::DuplicationInput.new(file_count: file_count, weighted_dup_mass: weighted_dup_mass, set_count: set_count)
  end

  def cov(hot: 0, cold: 0)
    S::CoverageInput.new(hot: hot, cold: cold)
  end

  def bnd(file_count: 1, weighted_violations: 0.0, violation_count: 0)
    S::BoundariesInput.new(file_count: file_count, weighted_violations: weighted_violations, violation_count: violation_count)
  end

  def inputs(complexity: nil, dead_code: nil, duplication: nil, coverage: nil, boundaries: nil)
    S::Inputs.new(complexity: complexity, dead_code: dead_code, duplication: duplication,
      coverage: coverage, boundaries: boundaries)
  end

  def score_of(composite, name)
    composite.components.find { |c| c.name == name }&.score
  end

  # ---- weights & grades are pinned -----------------------------------------

  def test_weights_sum_to_one
    assert_in_delta 1.0, S::WEIGHTS.values.sum, 0.0001
  end

  def test_grade_thresholds
    assert_equal "A", S.grade_for(1.0)
    assert_equal "A", S.grade_for(0.90)
    assert_equal "B", S.grade_for(0.899)
    assert_equal "B", S.grade_for(0.80)
    assert_equal "C", S.grade_for(0.799)
    assert_equal "C", S.grade_for(0.70)
    assert_equal "D", S.grade_for(0.60)
    assert_equal "F", S.grade_for(0.599)
    assert_equal "F", S.grade_for(0.0)
  end

  # ---- complexity: linear ratio, with a floor (churn-present branch) --------

  def test_complexity_with_churn_is_healthy_at_zero_risk
    c = S.assess(inputs(complexity: complexity(total_score: 0.0, churn_present: true)))
    assert_in_delta 1.0, score_of(c, "complexity"), 0.001
  end

  def test_complexity_with_churn_hits_half_at_half_the_knee
    # mean complexity*churn 150 vs knee 300 -> badness 0.5 -> (0.5*0.7)+0.3
    c = S.assess(inputs(complexity: complexity(file_count: 1, total_score: 150.0, churn_present: true)))
    assert_in_delta 0.65, score_of(c, "complexity"), 0.001
  end

  def test_complexity_floors_at_and_past_the_knee
    at = S.assess(inputs(complexity: complexity(total_score: 300.0, churn_present: true)))
    past = S.assess(inputs(complexity: complexity(total_score: 900.0, churn_present: true)))
    assert_in_delta S::COMPLEXITY_FLOOR, score_of(at, "complexity"), 0.001
    assert_in_delta S::COMPLEXITY_FLOOR, score_of(past, "complexity"), 0.001
  end

  # ---- complexity: the no-churn (no git) branch uses the ABC-only knee ------

  def test_complexity_without_churn_uses_the_complexity_only_knee
    # mean ABC per file 75 vs knee 150 -> badness 0.5 -> 0.65
    c = S.assess(inputs(complexity: complexity(file_count: 1, total_complexity: 75.0, churn_present: false)))
    component = c.components.find { |x| x.name == "complexity" }
    assert_in_delta 0.65, component.score, 0.001
    assert_equal :complexity_only_density, component.reasons.first.rule
  end

  # ---- dead code: confidence-weighted density vs the knee -------------------

  def test_dead_code_is_healthy_with_no_candidates
    c = S.assess(inputs(dead_code: dead(symbol_count: 100, confidence_sum: 0.0)))
    assert_in_delta 1.0, score_of(c, "dead_code"), 0.001
  end

  def test_dead_code_half_at_half_the_density_knee
    # density 0.06 vs knee 0.12 -> badness 0.5 -> 0.50
    c = S.assess(inputs(dead_code: dead(symbol_count: 100, confidence_sum: 6.0, finding_count: 10)))
    assert_in_delta 0.5, score_of(c, "dead_code"), 0.001
  end

  def test_dead_code_bottoms_out_at_the_density_knee
    c = S.assess(inputs(dead_code: dead(symbol_count: 100, confidence_sum: 12.0)))
    assert_in_delta 0.0, score_of(c, "dead_code"), 0.001
  end

  def test_unresolved_index_caps_dead_code_health
    c = S.assess(inputs(dead_code: dead(symbol_count: 100, confidence_sum: 0.0, resolved: false)))
    component = c.components.find { |x| x.name == "dead_code" }
    assert_in_delta S::DEADCODE_UNRESOLVED_CAP, component.score, 0.001
    assert_includes component.reasons.map(&:rule), :index_unresolved
  end

  def test_unresolved_cap_does_not_raise_an_already_lower_score
    component = S.assess(inputs(dead_code: dead(symbol_count: 100, confidence_sum: 6.0, resolved: false)))
      .components.find { |x| x.name == "dead_code" }
    assert_in_delta 0.5, component.score, 0.001
    refute_includes component.reasons.map(&:rule), :index_unresolved
  end

  # ---- duplication: confidence-weighted mass per file vs the knee -----------

  def test_duplication_is_healthy_with_no_clones
    c = S.assess(inputs(duplication: dup(weighted_dup_mass: 0.0)))
    assert_in_delta 1.0, score_of(c, "duplication"), 0.001
  end

  def test_duplication_half_at_half_the_burden_knee
    # burden 20 vs knee 40 -> 0.5 -> 0.50
    c = S.assess(inputs(duplication: dup(file_count: 1, weighted_dup_mass: 20.0)))
    assert_in_delta 0.5, score_of(c, "duplication"), 0.001
  end

  def test_duplication_bottoms_out_at_the_burden_knee
    c = S.assess(inputs(duplication: dup(file_count: 1, weighted_dup_mass: 40.0)))
    assert_in_delta 0.0, score_of(c, "duplication"), 0.001
  end

  # ---- coverage: cold ratio among tracked, untracked excluded ---------------

  def test_coverage_is_healthy_when_nothing_is_cold
    c = S.assess(inputs(coverage: cov(hot: 5, cold: 0)))
    assert_in_delta 1.0, score_of(c, "coverage"), 0.001
  end

  def test_coverage_half_when_half_cold
    c = S.assess(inputs(coverage: cov(hot: 5, cold: 5)))
    assert_in_delta 0.5, score_of(c, "coverage"), 0.001
  end

  def test_coverage_bottoms_out_when_all_tracked_is_cold
    c = S.assess(inputs(coverage: cov(hot: 0, cold: 10)))
    assert_in_delta 0.0, score_of(c, "coverage"), 0.001
  end

  # ---- boundaries: severity-weighted violations per file vs the knee --------

  def test_boundaries_is_healthy_with_no_violations
    c = S.assess(inputs(boundaries: bnd(weighted_violations: 0.0)))
    assert_in_delta 1.0, score_of(c, "boundaries"), 0.001
  end

  def test_boundaries_half_at_half_the_burden_knee
    # burden 2.0 vs knee 4.0 -> badness 0.5 -> 0.50
    c = S.assess(inputs(boundaries: bnd(file_count: 1, weighted_violations: 2.0, violation_count: 2)))
    assert_in_delta 0.5, score_of(c, "boundaries"), 0.001
  end

  def test_boundaries_bottoms_out_at_the_burden_knee
    c = S.assess(inputs(boundaries: bnd(file_count: 1, weighted_violations: 4.0, violation_count: 4)))
    assert_in_delta 0.0, score_of(c, "boundaries"), 0.001
  end

  def test_boundaries_is_vacuously_healthy_with_no_files
    component = S.assess(inputs(boundaries: bnd(file_count: 0))).components.find { |x| x.name == "boundaries" }
    assert_in_delta 1.0, component.score, 0.001
    assert_equal :no_signal, component.reasons.first.rule
  end

  def test_boundaries_category_ties_to_the_boundaries_contract
    component = S.assess(inputs(boundaries: bnd(weighted_violations: 0.0))).components.find { |x| x.name == "boundaries" }
    assert_equal "architecture_boundary", component.category
  end

  # ---- vacuous (healthy-by-absence) vs absent (nil) -------------------------

  def test_empty_denominators_are_vacuously_healthy_and_say_why
    c = S.assess(inputs(
      complexity: complexity(file_count: 0),
      dead_code: dead(symbol_count: 0),
      duplication: dup(file_count: 0),
      coverage: cov(hot: 0, cold: 0)
    ))
    %w[complexity dead_code duplication coverage].each do |name|
      component = c.components.find { |x| x.name == name }
      assert_in_delta 1.0, component.score, 0.001, "#{name} is vacuously healthy"
      assert_equal :no_signal, component.reasons.first.rule
    end
  end

  def test_absent_components_are_dropped_from_the_composite
    c = S.assess(inputs(complexity: complexity(total_score: 0.0)))
    assert_equal ["complexity"], c.components.map(&:name)
  end

  def test_no_components_yields_a_null_composite
    c = S.assess(inputs)
    assert_nil c.score
    assert_nil c.grade
    assert_empty c.components
  end

  # ---- the composite: weighted mean, renormalised over present components ----

  def test_composite_is_the_weighted_mean_of_all_present_components
    # complexity 1.0 (w .24), dead 0.50 (w .20), dup 1.0 (w .16), coverage 0.50 (w .20)
    # weighted = .24 + .10 + .16 + .10 = .60; total present weight = .80; .60/.80 = 0.75
    c = S.assess(inputs(
      complexity: complexity(total_score: 0.0),
      dead_code: dead(symbol_count: 100, confidence_sum: 6.0),
      duplication: dup(weighted_dup_mass: 0.0),
      coverage: cov(hot: 5, cold: 5)
    ))
    assert_in_delta 0.75, c.score, 0.001
    assert_equal "C", c.grade
  end

  def test_composite_renormalises_when_a_component_is_absent
    # Same three, no coverage/boundaries: (.24 + .10 + .16) / .60 = 0.8333
    c = S.assess(inputs(
      complexity: complexity(total_score: 0.0),
      dead_code: dead(symbol_count: 100, confidence_sum: 6.0),
      duplication: dup(weighted_dup_mass: 0.0)
    ))
    assert_in_delta 0.83, c.score, 0.001
    assert_equal "B", c.grade
  end

  def test_composite_includes_boundaries_when_present
    # complexity 1.0 (.24), dead 1.0 (.20), dup 1.0 (.16), boundaries 0.50 (.20)
    # weighted = .24 + .20 + .16 + .10 = .70; total = .80; .70/.80 -> 0.87 (rounded)
    c = S.assess(inputs(
      complexity: complexity(total_score: 0.0),
      dead_code: dead(symbol_count: 100, confidence_sum: 0.0),
      duplication: dup(weighted_dup_mass: 0.0),
      boundaries: bnd(file_count: 1, weighted_violations: 2.0, violation_count: 2)
    ))
    assert_in_delta 0.87, c.score, 0.001
    assert_includes c.components.map(&:name), "boundaries"
  end

  def test_normalized_weight_renormalises_over_present_components
    # The original four keep their relative proportions, so a boundaries-less repo
    # renormalises exactly as before the boundaries component was added.
    four = %w[complexity dead_code duplication coverage]
    assert_in_delta 0.30, S.normalized_weight("complexity", four), 0.0001
    # drop coverage: complexity's share rises to .24 / .60
    three = %w[complexity dead_code duplication]
    assert_in_delta 0.40, S.normalized_weight("complexity", three), 0.0001
  end

  # ---- a sub-score is never outside [0, 1] (humility / no overstatement) -----

  def test_sub_scores_stay_in_the_unit_interval
    extreme = S.assess(inputs(
      complexity: complexity(total_score: 99_999.0),
      dead_code: dead(symbol_count: 1, confidence_sum: 50.0),
      duplication: dup(weighted_dup_mass: 99_999.0),
      coverage: cov(hot: 0, cold: 99)
    ))
    extreme.components.each do |component|
      assert_operator component.score, :>=, 0.0
      assert_operator component.score, :<=, 1.0
    end
  end
end
