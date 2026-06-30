# frozen_string_literal: true

require "test_helper"

# The confidence model is a protected API, so it gets the heaviest coverage:
# base scores, every rule in isolation, clamping/rounding, composition, and the
# core invariant that no finding ever asserts certainty.
class TestConfidence < Minitest::Test
  Span = Moult::Span
  C = Moult::Confidence

  def ctx(**overrides)
    defaults = {
      symbol_id: "lib/foo.rb:1:Foo#bar",
      kind: :method,
      name: "Foo#bar",
      span: Span.new(start_line: 1, start_column: 0, end_line: 2, end_column: 3),
      path: "lib/foo.rb",
      visibility: :public,
      reference_count: 0,
      test_only: false,
      rails_signals: [],
      dynamic_dispatch: false,
      override_of: nil,
      deprecated: false,
      index_resolved: true,
      runtime: nil
    }
    C::Context.new(**defaults.merge(overrides))
  end

  # Run score with only the named default rules, so a single rule's effect is
  # isolated from the rest of the set.
  def only(*names)
    C::Rules::DEFAULT_RULES.select { |r| names.include?(r.name) }
  end

  def reason(finding, name)
    finding.reasons.find { |r| r.rule == name }
  end

  # ---- base scores ----------------------------------------------------------

  def test_base_score_by_kind_and_visibility
    {
      [:method, :private] => 0.75,
      [:method, :protected] => 0.6,
      [:method, :public] => 0.4,
      [:constant, :private] => 0.6,
      [:constant, :public] => 0.5
    }.each do |(kind, vis), expected|
      finding = C.score(ctx(kind: kind, visibility: vis), rules: [])
      assert_in_delta expected, finding.confidence, 0.001, "#{kind}/#{vis}"
      assert_equal expected, reason(finding, :base_score).delta
    end
  end

  def test_unknown_visibility_falls_back_to_default_base
    finding = C.score(ctx(kind: :method, visibility: :weird), rules: [])
    assert_in_delta C::DEFAULT_BASE, finding.confidence, 0.001
  end

  # ---- individual rules -----------------------------------------------------

  def test_no_references_records_reason_without_changing_score
    finding = C.score(ctx(visibility: :public, reference_count: 0), rules: only(:no_references))
    assert_in_delta 0.4, finding.confidence, 0.001
    refute_nil reason(finding, :no_references)
  end

  def test_test_only_references_lower_confidence
    base = C.score(ctx(visibility: :private), rules: []).confidence
    finding = C.score(ctx(visibility: :private, test_only: true), rules: only(:has_test_only_references))
    assert_in_delta base - 0.2, finding.confidence, 0.001
    assert_equal(-0.2, reason(finding, :has_test_only_references).delta)
  end

  def test_rails_entrypoint_strongly_lowers_and_keeps_detail
    sig = Moult::RailsConventions::Signal.new(rule: :rails_controller_action, detail: "public action in *_controller.rb")
    finding = C.score(ctx(visibility: :public, rails_signals: [sig]), rules: only(:rails_entrypoint))
    # base 0.4 - 0.5 = -0.1 -> clamped to 0.0
    assert_equal 0.0, finding.confidence
    assert_includes reason(finding, :rails_entrypoint).detail, "public action in *_controller.rb"
  end

  def test_dynamic_dispatch_lowers_confidence_but_keeps_finding
    finding = C.score(ctx(visibility: :private, dynamic_dispatch: true), rules: only(:dynamic_dispatch_present))
    assert_in_delta 0.75 - 0.35, finding.confidence, 0.001
    refute_nil reason(finding, :dynamic_dispatch_present), "must record, never hide"
  end

  def test_private_unused_raises_confidence
    finding = C.score(ctx(kind: :method, visibility: :private, reference_count: 0), rules: only(:private_unused))
    assert_in_delta 0.75 + 0.1, finding.confidence, 0.001
  end

  def test_public_api_lowers_confidence
    finding = C.score(ctx(kind: :method, visibility: :public), rules: only(:public_api))
    assert_in_delta 0.4 - 0.1, finding.confidence, 0.001
  end

  def test_constructor_is_lowered_as_implicit_entrypoint
    finding = C.score(ctx(name: "Foo#initialize", visibility: :public), rules: only(:implicit_constructor))
    assert_in_delta 0.4 - 0.4, finding.confidence, 0.001
    refute_nil reason(finding, :implicit_constructor)
  end

  def test_non_constructor_method_unaffected_by_constructor_rule
    finding = C.score(ctx(name: "Foo#bar", visibility: :public), rules: only(:implicit_constructor))
    assert_nil reason(finding, :implicit_constructor)
  end

  def test_override_lowers_confidence_and_names_the_ancestor
    finding = C.score(ctx(visibility: :public, override_of: "App::Base#run"), rules: only(:overrides_ancestor))
    assert_in_delta 0.4 - 0.4, finding.confidence, 0.001
    assert_includes reason(finding, :overrides_ancestor).detail, "App::Base#run"
  end

  def test_no_override_rule_when_not_overriding
    finding = C.score(ctx(visibility: :public, override_of: nil), rules: only(:overrides_ancestor))
    assert_nil reason(finding, :overrides_ancestor)
  end

  def test_deprecated_raises_confidence
    finding = C.score(ctx(visibility: :public, deprecated: true), rules: only(:deprecated_marked))
    assert_in_delta 0.4 + 0.1, finding.confidence, 0.001
  end

  def test_index_unresolved_caps_confidence
    finding = C.score(ctx(kind: :method, visibility: :private, index_resolved: false),
      rules: only(:private_unused, :index_unresolved))
    # 0.75 + 0.1 = 0.85, capped to 0.5
    assert_equal 0.5, finding.confidence
  end

  # ---- runtime (Phase 3) ----------------------------------------------------

  def test_runtime_cold_raises_confidence_and_records_reason
    finding = C.score(ctx(visibility: :private, runtime: :cold), rules: only(:runtime_cold))
    assert_in_delta 0.75 + 0.2, finding.confidence, 0.001
    assert_equal(0.2, reason(finding, :runtime_cold).delta)
    assert_equal :cold, finding.runtime
  end

  def test_runtime_hot_rescues_via_cap
    # The strongest static candidate (private, unused) is still driven below the
    # default gate when it executed at runtime.
    finding = C.score(ctx(kind: :method, visibility: :private, reference_count: 0, runtime: :hot),
      rules: only(:private_unused, :runtime_hot))
    assert_operator finding.confidence, :<=, 0.1
    refute_nil reason(finding, :runtime_hot), "must record the rescue, never hide it"
    assert_equal :hot, finding.runtime
  end

  def test_untracked_runtime_fires_no_rule
    finding = C.score(ctx(runtime: :untracked), rules: only(:runtime_cold, :runtime_hot))
    assert_nil reason(finding, :runtime_cold)
    assert_nil reason(finding, :runtime_hot)
    assert_equal :untracked, finding.runtime
  end

  def test_nil_runtime_carries_through_to_finding
    finding = C.score(ctx(runtime: nil))
    assert_nil finding.runtime
    assert_nil finding.to_h[:runtime]
  end

  # ---- composition, clamping, rounding, invariants --------------------------

  def test_clamps_to_unit_interval
    sig = Moult::RailsConventions::Signal.new(rule: :rails_job_perform, detail: "job #perform")
    finding = C.score(ctx(visibility: :public, rails_signals: [sig], dynamic_dispatch: true))
    assert_operator finding.confidence, :>=, 0.0
    assert_operator finding.confidence, :<=, 1.0
  end

  def test_rounds_to_two_decimals
    finding = C.score(ctx(visibility: :public))
    assert_equal finding.confidence.round(2), finding.confidence
  end

  def test_reasons_always_include_base_and_confidence_in_unit_interval
    finding = C.score(ctx(kind: :method, visibility: :private, reference_count: 0))
    assert_equal :base_score, finding.reasons.first.rule
    assert_operator finding.confidence, :>=, 0.0
    assert_operator finding.confidence, :<=, 1.0
  end

  def test_category_is_dead_code_and_never_certain
    finding = C.score(ctx(kind: :method, visibility: :private))
    assert_equal "dead_code", finding.category
    refute_respond_to finding, :dead?
    refute finding.to_h.key?(:dead)
    refute finding.to_h.key?(:certain)
  end

  def test_to_h_shape
    sig = Moult::RailsConventions::Signal.new(rule: :rails_helper, detail: "helper method")
    h = C.score(ctx(visibility: :public, rails_signals: [sig], runtime: :hot)).to_h
    assert_equal %i[symbol_id kind name span confidence category runtime reasons].sort, h.keys.sort
    assert_equal "method", h[:kind]
    assert_equal "hot", h[:runtime]
    assert h[:reasons].all? { |r| r.keys.sort == %i[rule delta detail].sort }
  end
end
