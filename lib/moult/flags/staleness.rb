# frozen_string_literal: true

module Moult
  module Flags
    # The confidence-graded per-finding model for feature-flag STALENESS — this
    # slice's first real use of Moult's protected per-finding confidence API. Where
    # {Classification} grades recorded USAGE (a reference is a fact, so its confidence
    # is null), staleness is a genuine judgement: given a flag's observed references
    # and the state the provider snapshot reports for its key, how strong a candidate
    # is it for removal?
    #
    # Like the static<->runtime coverage merge (see {Coverage::Resolver}), the
    # snapshot is EVIDENCE, not proof. A flag is never asserted certainly stale or
    # dead. The provider state (archived / disabled / fully rolled out) and the
    # join result (absent — referenced in code, unknown to the provider) raise
    # confidence; dynamic, non-literal keys in the codebase LOWER it, because the
    # snapshot may be partial or the key resolved dynamically.
    #
    # {classify} is a pure function of the joined facts — no IO, no Prism, no clock —
    # so it is pinned against hand-built inputs exactly like {ABC}, the coverage
    # {Resolver}, the duplication {Confidence} model, {Boundaries::Severity}, and
    # {Classification}. The statuses and confidence knees are deliberate v1
    # heuristics; drift is a bug.
    #
    # Time-based "stale-since" decay (a flag untouched for N days) is deferred: it
    # needs a +now+ clock and a threshold knee, so it would make this model impure.
    # The snapshot's +exported_at+ and a flag's +updated_at+ are captured as evidence
    # to seed it later, exactly as coverage captured +collected_at+ while deferring
    # stale-detection.
    module Staleness
      # The provider explicitly retired the flag. The strongest removal candidate.
      ARCHIVED = "archived"
      # Referenced in code, but the snapshot has no such key (deleted/renamed in the
      # provider, or managed elsewhere). Strong, but humbled by dynamic references.
      ABSENT = "absent"
      # Disabled in the provider (served to no one): the enabled branch is unreachable.
      DISABLED = "disabled"
      # Fully rolled out (enabled, no targeting — one variant served to all): the
      # other branch is never taken.
      ROLLED_OUT = "rolled_out"
      # Enabled with targeting (serving multiple variations): actively evaluated,
      # NOT a removal candidate.
      ACTIVE = "active"

      STATUSES = [ARCHIVED, ABSENT, DISABLED, ROLLED_OUT, ACTIVE].freeze

      # Pinned confidence knees per status (removal-candidate strength).
      ARCHIVED_CONFIDENCE = 0.9
      ABSENT_CONFIDENCE = 0.7
      ROLLED_OUT_CONFIDENCE = 0.6
      DISABLED_CONFIDENCE = 0.5
      ACTIVE_CONFIDENCE = 0.0

      # Humility modifier: subtracted from an +absent+ candidate when the codebase
      # has dynamic (non-literal-key) flag references — the key the static scan could
      # not resolve may BE this one, so the snapshot's silence is less trustworthy.
      DYNAMIC_REFERENCE_PENALTY = 0.2

      # One auditable note behind a staleness judgement. Local to the flags slice
      # (like {Classification::Reason}); categorical, so no +delta+.
      Reason = Struct.new(:rule, :detail) do
        def to_h
          {rule: rule.to_s, detail: detail}
        end
      end

      # The graded result: the staleness status, its confidence in [0, 1], and the
      # reasons behind them.
      Assessment = Struct.new(:status, :confidence, :reasons) do
        def to_h
          {status: status, confidence: confidence, reasons: reasons.map(&:to_h)}
        end
      end

      module_function

      # @param state [Snapshot::FlagState, nil] the provider's state for this key, or
      #   nil when the snapshot does not know the key (an +absent+ candidate)
      # @param has_dynamic_references [Boolean] whether the codebase has any dynamic
      #   (non-literal-key) flag references (a snapshot-completeness caveat)
      # @return [Assessment]
      def classify(state:, has_dynamic_references: false)
        return absent(has_dynamic_references) if state.nil?
        return archived(state) if state.archived
        return disabled(state) if state.enabled == false
        return rolled_out(state) if state.enabled && !state.has_targeting
        active(state)
      end

      def absent(has_dynamic_references)
        reasons = [Reason.new(rule: :absent_from_provider,
          detail: "referenced in code but unknown to the provider snapshot (deleted or renamed in the provider); a candidate for removal")]
        confidence = ABSENT_CONFIDENCE
        if has_dynamic_references
          confidence -= DYNAMIC_REFERENCE_PENALTY
          reasons << Reason.new(rule: :dynamic_references,
            detail: "the codebase has dynamic (non-literal) flag keys, so the snapshot may be incomplete; confidence lowered")
        end
        assess(ABSENT, confidence, reasons)
      end

      def archived(state)
        reasons = [Reason.new(rule: :provider_archived,
          detail: "the provider marks this flag archived/retired; a strong candidate for removal")]
        reasons << updated_at_reason(state)
        assess(ARCHIVED, ARCHIVED_CONFIDENCE, reasons.compact)
      end

      def disabled(state)
        reasons = [Reason.new(rule: :provider_disabled,
          detail: "disabled in the provider (served to no one); the enabled branch is unreachable — a candidate for removal")]
        reasons << updated_at_reason(state)
        assess(DISABLED, DISABLED_CONFIDENCE, reasons.compact)
      end

      def rolled_out(state)
        reasons = [Reason.new(rule: :fully_rolled_out,
          detail: "enabled with no targeting (one variant served to all); the other branch is never taken — a candidate for removal")]
        reasons << updated_at_reason(state)
        assess(ROLLED_OUT, ROLLED_OUT_CONFIDENCE, reasons.compact)
      end

      def active(_state)
        reasons = [Reason.new(rule: :active,
          detail: "enabled with targeting (serving multiple variations); actively evaluated — not a removal candidate")]
        assess(ACTIVE, ACTIVE_CONFIDENCE, reasons)
      end

      # An evidence note for a captured last-modified timestamp (deferred time-decay
      # seed). nil when the snapshot recorded none, so it is compacted out.
      def updated_at_reason(state)
        return nil unless state.updated_at
        Reason.new(rule: :last_modified, detail: "provider last modified this flag at #{state.updated_at}")
      end

      def assess(status, confidence, reasons)
        Assessment.new(status: status, confidence: clamp(confidence), reasons: reasons)
      end

      def clamp(value)
        value.clamp(0.0, 1.0).round(2)
      end
    end
  end
end
