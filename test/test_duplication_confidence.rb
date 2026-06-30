# frozen_string_literal: true

require "test_helper"

# The duplication confidence model grades how likely a clone group is genuine,
# consolidatable duplication. Like the ABC metric and the coverage resolver, its
# scoring is pinned against hand-built inputs — drift is a bug. The function is
# pure (no flay), so every rule combination is exercised in isolation.
class TestDuplicationConfidence < Minitest::Test
  C = Moult::Duplication::Confidence

  def assess(kind:, mass:, occ:, node:)
    C.assess(kind: kind, mass: mass, occurrence_count: occ, node_type: node)
  end

  def confidence(**)
    assess(**).confidence
  end

  def rules(**)
    assess(**).reasons.map(&:rule)
  end

  # ---- base, by kind --------------------------------------------------------

  def test_identical_small_fragment_is_base_only
    # 0.60 base, mass below the medium bucket, 2 occurrences, expression node.
    assert_in_delta 0.6, confidence(kind: :identical, mass: 20, occ: 2, node: "call"), 0.001
  end

  def test_similar_small_fragment_is_base_only
    assert_in_delta 0.45, confidence(kind: :similar, mass: 20, occ: 2, node: "call"), 0.001
  end

  # ---- mass buckets (boundaries pinned) -------------------------------------

  def test_mass_just_below_medium_adds_nothing
    assert_in_delta 0.6, confidence(kind: :identical, mass: 39, occ: 2, node: "call"), 0.001
    refute_includes rules(kind: :identical, mass: 39, occ: 2, node: "call"), :medium_mass
  end

  def test_medium_mass_adds_a_tenth
    # 0.60 + 0.10
    assert_in_delta 0.7, confidence(kind: :identical, mass: 40, occ: 2, node: "call"), 0.001
    assert_in_delta 0.7, confidence(kind: :identical, mass: 99, occ: 2, node: "call"), 0.001
  end

  def test_large_mass_adds_a_fifth
    # 0.60 + 0.20
    assert_in_delta 0.8, confidence(kind: :identical, mass: 100, occ: 2, node: "call"), 0.001
  end

  # ---- occurrence count -----------------------------------------------------

  def test_two_occurrences_get_no_bonus
    refute_includes rules(kind: :identical, mass: 20, occ: 2, node: "call"), :many_occurrences
  end

  def test_three_or_more_occurrences_add_a_bonus
    # 0.60 + 0.07
    assert_in_delta 0.67, confidence(kind: :identical, mass: 20, occ: 3, node: "call"), 0.001
  end

  # ---- whole-definition alignment -------------------------------------------

  def test_whole_definition_node_types_add_a_bonus
    %w[defn defs class module sclass].each do |node|
      assert_includes rules(kind: :identical, mass: 20, occ: 2, node: node), :whole_definition, "#{node} is a whole definition"
      assert_in_delta 0.68, confidence(kind: :identical, mass: 20, occ: 2, node: node), 0.001
    end
  end

  def test_expression_node_types_get_no_whole_definition_bonus
    %w[call cdecl iter if block].each do |node|
      refute_includes rules(kind: :identical, mass: 20, occ: 2, node: node), :whole_definition
    end
  end

  # ---- the strongest identical case (still never certain) -------------------

  def test_identical_large_multicopy_whole_method_tops_out_below_one
    # 0.60 + 0.20 (large) + 0.07 (3x) + 0.08 (defn) = 0.95
    assert_in_delta 0.95, confidence(kind: :identical, mass: 240, occ: 3, node: "defn"), 0.001
  end

  # ---- the similarity cap: shared shape is not proof of shared intent -------

  def test_strong_similar_match_is_capped
    # raw 0.45 + 0.20 + 0.07 + 0.08 = 0.80 -> capped to 0.75
    a = assess(kind: :similar, mass: 240, occ: 3, node: "defn")
    assert_in_delta 0.75, a.confidence, 0.001
    assert_includes a.reasons.map(&:rule), :similar_cap
  end

  def test_similar_match_under_the_cap_is_not_flagged
    a = assess(kind: :similar, mass: 100, occ: 2, node: "call") # 0.45 + 0.20 = 0.65
    assert_in_delta 0.65, a.confidence, 0.001
    refute_includes a.reasons.map(&:rule), :similar_cap
  end

  # ---- reasons are auditable ------------------------------------------------

  def test_base_reason_detail_distinguishes_identical_from_similar
    identical = assess(kind: :identical, mass: 20, occ: 2, node: "call").reasons.first
    similar = assess(kind: :similar, mass: 20, occ: 2, node: "call").reasons.first
    assert_equal :base_score, identical.rule
    assert_match(/identical/, identical.detail)
    assert_match(/similar/, similar.detail)
  end

  def test_confidence_is_rounded_to_two_decimals
    value = confidence(kind: :identical, mass: 20, occ: 3, node: "call")
    assert_equal value.round(2), value
  end
end
