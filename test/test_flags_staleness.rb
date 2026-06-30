# frozen_string_literal: true

require "test_helper"

# Pins the pure feature-flag STALENESS model. Like {ABC}, the coverage {Resolver},
# the duplication {Confidence} model, {Boundaries::Severity}, and {Flags::Classification},
# the status + confidence mapping is fixed against hand-built inputs. The function is
# pure (no IO, no Prism, no clock), so every case is exercised in isolation. Drift is
# a bug.
#
# This is the flags slice's first confidence-graded signal: the merge POPULATES the
# reserved confidence slot. The humility invariant is enforced here too — a flag is
# never asserted certainly stale/dead; the confidence is bounded and the reasons say
# "candidate," never "dead/unused/obsolete."
class TestFlagsStaleness < Minitest::Test
  S = Moult::Flags::Staleness
  State = Moult::Flags::Snapshot::FlagState

  def state(enabled:, archived: false, has_targeting: false, updated_at: nil)
    State.new(key: "k", enabled: enabled, archived: archived, has_targeting: has_targeting,
      default_variant: nil, updated_at: updated_at)
  end

  # ---- status classification (precedence top-to-bottom) ---------------------

  def test_absent_when_the_provider_does_not_know_the_key
    a = S.classify(state: nil)
    assert_equal S::ABSENT, a.status
    assert_in_delta S::ABSENT_CONFIDENCE, a.confidence, 1e-9
  end

  def test_archived_when_the_provider_marks_it_archived
    a = S.classify(state: state(enabled: true, archived: true, has_targeting: true))
    assert_equal S::ARCHIVED, a.status
    assert_in_delta S::ARCHIVED_CONFIDENCE, a.confidence, 1e-9
  end

  def test_archived_takes_precedence_over_enabled_or_targeting
    # An archived flag still ENABLED with targeting is archived, not active.
    a = S.classify(state: state(enabled: true, archived: true, has_targeting: true))
    assert_equal S::ARCHIVED, a.status
  end

  def test_disabled_when_state_is_off
    a = S.classify(state: state(enabled: false))
    assert_equal S::DISABLED, a.status
    assert_in_delta S::DISABLED_CONFIDENCE, a.confidence, 1e-9
  end

  def test_rolled_out_when_enabled_without_targeting
    a = S.classify(state: state(enabled: true, has_targeting: false))
    assert_equal S::ROLLED_OUT, a.status
    assert_in_delta S::ROLLED_OUT_CONFIDENCE, a.confidence, 1e-9
  end

  def test_active_when_enabled_with_targeting
    a = S.classify(state: state(enabled: true, has_targeting: true))
    assert_equal S::ACTIVE, a.status
    assert_in_delta S::ACTIVE_CONFIDENCE, a.confidence, 1e-9
    assert_equal 0.0, a.confidence, "active is not a removal candidate"
  end

  # ---- the humility modifier -------------------------------------------------

  def test_dynamic_references_lower_absent_confidence_only
    base = S.classify(state: nil, has_dynamic_references: false)
    humbled = S.classify(state: nil, has_dynamic_references: true)
    assert_in_delta S::ABSENT_CONFIDENCE, base.confidence, 1e-9
    assert_in_delta(S::ABSENT_CONFIDENCE - S::DYNAMIC_REFERENCE_PENALTY, humbled.confidence, 1e-9)
    assert(humbled.reasons.any? { |r| r.rule == :dynamic_references })
  end

  def test_dynamic_references_do_not_change_a_known_flag
    with = S.classify(state: state(enabled: true), has_dynamic_references: true)
    without = S.classify(state: state(enabled: true), has_dynamic_references: false)
    assert_equal without.confidence, with.confidence
  end

  # ---- evidence + audit trail ------------------------------------------------

  def test_a_captured_timestamp_surfaces_as_a_reason
    a = S.classify(state: state(enabled: false, updated_at: "2025-01-15T00:00:00Z"))
    assert(a.reasons.any? { |r| r.rule == :last_modified && r.detail.include?("2025-01-15") })
  end

  def test_no_timestamp_means_no_last_modified_reason
    a = S.classify(state: state(enabled: false))
    refute(a.reasons.any? { |r| r.rule == :last_modified })
  end

  def test_every_status_carries_at_least_one_reason
    [nil, state(enabled: true, archived: true), state(enabled: false),
      state(enabled: true), state(enabled: true, has_targeting: true)].each do |st|
      a = S.classify(state: st)
      refute_empty a.reasons
      assert(a.reasons.all? { |r| r.rule && r.detail })
    end
  end

  def test_confidence_is_always_a_bounded_unit_interval
    [nil, state(enabled: true, archived: true), state(enabled: false),
      state(enabled: true)].each do |st|
      a = S.classify(state: st, has_dynamic_references: true)
      assert_operator a.confidence, :>=, 0.0
      assert_operator a.confidence, :<=, 1.0
    end
  end

  def test_no_reason_asserts_certain_death
    forbidden = /\b(dead|unused|obsolete)\b/i
    [nil, state(enabled: true, archived: true), state(enabled: false),
      state(enabled: true), state(enabled: true, has_targeting: true)].each do |st|
      a = S.classify(state: st, has_dynamic_references: true)
      a.reasons.each do |r|
        refute_match forbidden, r.detail, "a staleness reason must stay a candidate, never assert death: #{r.detail.inspect}"
      end
    end
  end

  def test_statuses_constant_lists_exactly_the_emitted_statuses
    emitted = [
      S.classify(state: nil),
      S.classify(state: state(enabled: true, archived: true)),
      S.classify(state: state(enabled: false)),
      S.classify(state: state(enabled: true)),
      S.classify(state: state(enabled: true, has_targeting: true))
    ].map(&:status).uniq.sort
    assert_equal S::STATUSES.sort, emitted
  end
end
