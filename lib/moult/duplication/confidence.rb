# frozen_string_literal: true

module Moult
  module Duplication
    # The per-finding confidence model for duplication — the duplication slice's
    # realisation of Moult's protected confidence API. It answers a deliberately
    # humble question: *how confident are we that this clone group is genuine,
    # consolidatable duplication* rather than an incidental structural rhyme? It
    # never asserts certainty; every contributing factor is recorded as a {Reason}
    # so the judgement is auditable.
    #
    # {assess} is a pure function of the signals flay hands us (already extracted
    # by {Clones}): no IO, no flay objects. That keeps it trivially unit-testable
    # and lets the scoring be pinned against hand-built inputs — drift is a bug,
    # the same treatment {ABC} and the coverage {Resolver} get.
    module Confidence
      CATEGORY = "duplication"

      # Base likelihood before any adjustment, keyed by kind. An *identical*
      # (byte-for-byte) match is near-certain duplication; a merely *similar*
      # match (names/literals differ) is weaker and could be parallel-by-design.
      BASE = {identical: 0.6, similar: 0.45}.freeze

      # A structurally-similar (not identical) match never reaches high confidence:
      # shared shape is not proof of shared intent.
      SIMILAR_CAP = 0.75

      # Larger duplicated structures are far less likely to be coincidental.
      MASS_LARGE = 100
      MASS_MEDIUM = 40

      # sexp node types that are whole, cleanly-extractable definitions. A
      # duplicated whole method/class is the least ambiguous "consolidate me".
      WHOLE_DEFINITION = %w[defn defs class module sclass].freeze

      # One auditable contribution to a finding's confidence. Mirrors the shared
      # rule/delta/detail reason shape used across Moult's contracts; kept local so
      # the duplication slice does not couple to the dead-code Confidence module.
      Reason = Struct.new(:rule, :delta, :detail) do
        def to_h
          {rule: rule.to_s, delta: delta, detail: detail}
        end
      end

      # The graded result: a confidence in [0, 1] and the reasons behind it.
      Assessment = Struct.new(:confidence, :reasons)

      module_function

      # @param kind [Symbol] :identical or :similar
      # @param mass [Integer] flay's mass for the duplicated node
      # @param occurrence_count [Integer] number of sites (>= 2)
      # @param node_type [String] flay sexp type, e.g. "defn", "call"
      # @return [Assessment]
      def assess(kind:, mass:, occurrence_count:, node_type:)
        base = BASE.fetch(kind, BASE[:similar])
        reasons = [Reason.new(rule: :base_score, delta: base, detail: base_detail(kind))]

        mass_contribution = mass_reason(mass)
        reasons << mass_contribution if mass_contribution
        reasons << Reason.new(rule: :many_occurrences, delta: 0.07, detail: "duplicated across #{occurrence_count} locations") if occurrence_count >= 3
        reasons << Reason.new(rule: :whole_definition, delta: 0.08, detail: "duplicates a whole #{node_type}") if WHOLE_DEFINITION.include?(node_type)

        raw = reasons.sum(&:delta)
        if kind == :similar && raw > SIMILAR_CAP
          reasons << Reason.new(rule: :similar_cap, delta: 0.0, detail: "structural similarity is not proof of duplication; capped at #{SIMILAR_CAP}")
          raw = SIMILAR_CAP
        end

        Assessment.new(confidence: raw.clamp(0.0, 1.0).round(2), reasons: reasons)
      end

      def base_detail(kind)
        if kind == :identical
          "identical structural match (byte-for-byte)"
        else
          "structurally-similar match (names/literals differ)"
        end
      end

      # Bucketed so the contribution is stable and pinnable regardless of the
      # run's configurable --min-mass.
      def mass_reason(mass)
        if mass >= MASS_LARGE
          Reason.new(rule: :large_mass, delta: 0.2, detail: "large duplicated mass (#{mass})")
        elsif mass >= MASS_MEDIUM
          Reason.new(rule: :medium_mass, delta: 0.1, detail: "moderate duplicated mass (#{mass})")
        end
      end
    end
  end
end
