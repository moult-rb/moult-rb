# frozen_string_literal: true

require "test_helper"

# The boundaries per-finding model is the slice's realisation of Moult's protected
# per-finding API. Unlike dead code / duplication it grades by SEVERITY (a packwerk
# violation is a recorded fact, not a probabilistic candidate). Like the ABC metric,
# the coverage resolver, and the duplication confidence model, the mapping is pinned
# against hand-built inputs — drift is a bug. The function is pure (no IO), so every
# violation type is exercised in isolation.
class TestBoundariesSeverity < Minitest::Test
  S = Moult::Boundaries::Severity

  def severity(type)
    S.classify(violation_type: type).severity
  end

  # ---- the mapping is pinned -------------------------------------------------

  def test_dependency_is_high
    assert_equal "high", severity("dependency")
  end

  def test_layer_is_high
    assert_equal "high", severity("layer")
  end

  def test_privacy_is_medium
    assert_equal "medium", severity("privacy")
  end

  def test_visibility_is_medium
    assert_equal "medium", severity("visibility")
  end

  def test_folder_privacy_is_medium
    assert_equal "medium", severity("folder_privacy")
  end

  def test_unknown_type_degrades_to_low_not_dropped
    assert_equal "low", severity("some_future_checker")
  end

  # ---- the pinned constants --------------------------------------------------

  def test_scale_is_ordered_low_to_high
    assert_equal %w[low medium high], S::SCALE
  end

  def test_severity_weights_are_pinned_and_monotonic
    assert_equal({"high" => 1.0, "medium" => 0.6, "low" => 0.3}, S::SEVERITY_WEIGHT)
    assert_operator S::SEVERITY_WEIGHT["high"], :>, S::SEVERITY_WEIGHT["medium"]
    assert_operator S::SEVERITY_WEIGHT["medium"], :>, S::SEVERITY_WEIGHT["low"]
  end

  def test_every_known_severity_has_a_weight
    S::SEVERITY.each_value { |sev| assert S::SEVERITY_WEIGHT.key?(sev), "#{sev} needs a weight" }
    assert S::SEVERITY_WEIGHT.key?(S::DEFAULT_SEVERITY)
  end

  # ---- the assessment is auditable and humble --------------------------------

  def test_classification_records_an_auditable_reason
    assessment = S.classify(violation_type: "dependency")
    assert_equal 1, assessment.reasons.size
    reason = assessment.reasons.first
    assert_equal :dependency_violation, reason.rule
    refute_empty reason.detail
  end

  def test_category_is_architecture_boundary
    assert_equal "architecture_boundary", S::CATEGORY
  end

  def test_no_reason_asserts_the_code_is_wrong
    S::SEVERITY.keys.each do |type|
      detail = S.classify(violation_type: type).reasons.first.detail.downcase
      refute_includes detail, "certain"
      refute_includes detail, "definitely"
    end
  end
end
