# frozen_string_literal: true

require "test_helper"

# The flags per-finding model is the slice's realisation of Moult's protected
# per-finding API. Like {Boundaries::Severity} it grades a recorded FACT (a flag
# reference) categorically — by value_type, reference count and observed defaults —
# never with a manufactured confidence. Like the ABC metric, the coverage resolver,
# the duplication confidence model and the boundaries severity model, the mapping is
# pinned against hand-built inputs. The function is pure (no IO), so every case is
# exercised in isolation. Drift is a bug.
class TestFlagsClassification < Minitest::Test
  C = Moult::Flags::Classification

  def classify(types, defaults = [])
    C.classify(value_types: types, default_values: defaults)
  end

  # ---- value_type resolution is pinned ---------------------------------------

  def test_single_boolean_resolves_to_boolean
    assert_equal "boolean", classify(%w[boolean]).value_type
  end

  def test_consistent_type_across_sites_resolves_to_that_type
    assert_equal "string", classify(%w[string string string]).value_type
  end

  def test_mixed_types_resolve_to_unknown
    assert_equal "unknown", classify(%w[boolean string]).value_type
  end

  def test_every_known_value_type_is_in_the_enum
    %w[boolean string number object].each do |t|
      assert_includes C::VALUE_TYPES, classify([t]).value_type
    end
    assert_includes C::VALUE_TYPES, C::MIXED
  end

  # ---- reference count and defaults ------------------------------------------

  def test_reference_count_is_the_number_of_sites
    assert_equal 3, classify(%w[number number number]).reference_count
  end

  def test_default_values_are_deduped_compacted_and_sorted
    assessment = classify(%w[string string string], ["b", "a", "a", nil])
    assert_equal %w[a b], assessment.default_values
  end

  def test_no_literal_defaults_yields_an_empty_list
    assert_empty classify(%w[object], [nil]).default_values
  end

  # ---- reasons are auditable and humble --------------------------------------

  def test_typed_flag_records_a_typed_reason
    rules = classify(%w[boolean boolean]).reasons.map(&:rule)
    assert_includes rules, :boolean_flag
    assert_includes rules, :reference_count
  end

  def test_mixed_flag_records_a_mixed_reason
    rules = classify(%w[boolean number]).reasons.map(&:rule)
    assert_includes rules, :mixed_value_types
  end

  def test_default_values_reason_only_present_when_defaults_exist
    assert_includes classify(%w[string], ["x"]).reasons.map(&:rule), :default_values
    refute_includes classify(%w[string], [nil]).reasons.map(&:rule), :default_values
  end

  def test_category_is_feature_flag
    assert_equal "feature_flag", C::CATEGORY
  end

  def test_no_reason_asserts_staleness_or_death
    detail = classify(%w[boolean]).reasons.map(&:detail).join(" ").downcase
    refute_includes detail, "stale"
    refute_includes detail, "dead"
    refute_includes detail, "unused"
  end
end
