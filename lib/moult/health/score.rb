# frozen_string_literal: true

module Moult
  module Health
    # The pure model that turns the other analyses' signals into one composite
    # health score. This slice's realisation of Moult's protected confidence API:
    # it answers a deliberately humble question — *how healthy does this codebase
    # look, given the signals we have* — and it is never a verdict. Every component
    # records the observation behind its sub-score as a {Reason}, and the composite
    # records which components contributed, so the number is auditable.
    #
    # {assess} is a pure function of small numeric inputs ({Inputs} and the per-
    # analysis +*Input+ structs) — no IO, no report objects. That keeps it trivially
    # unit-testable and lets the scoring be pinned against hand-built inputs: drift
    # is a bug, the same treatment {ABC}, the coverage {Resolver}, and the
    # duplication {Confidence} model get.
    #
    # The single inversion to keep in mind: the four input analyses all score
    # *badness* (higher = worse). Health scores *goodness* (1.0 = healthy). Every
    # normalisation converts a bounded badness ratio b in [0, 1] to a health
    # sub-score via {health_from_badness} — the one audited inversion point.
    module Score
      # ---- pinned weights -----------------------------------------------------
      # Static weight of each built-in component; they sum to 1.0 and are
      # renormalised over whatever components are actually present. Complexity
      # anchors the composite — it is the only signal that means something with no
      # git history and no coverage. Coverage and dead code tie: both are strong
      # "is this code used" signals but each is conditional. Duplication is the
      # softest health signal (sometimes deliberate), so it gets the smallest share.
      # Boundaries (conditional: only packwerk projects) joins as a structural signal;
      # the original four kept their RELATIVE proportions (each scaled by 0.8) so a
      # repo without boundaries scores and renormalises exactly as before.
      WEIGHTS = {
        "complexity" => 0.24,
        "dead_code" => 0.20,
        "duplication" => 0.16,
        "coverage" => 0.20,
        "boundaries" => 0.20
      }.freeze

      # ---- pinned grade thresholds (inclusive lower bounds on the composite) ---
      # Letter grades on a normalised score follow the conventions of established
      # code-health tools (Code Climate's A–F maintainability grade, SonarQube's
      # A–E maintainability rating, CodeScene's 1–10 Code Health). The density/ratio
      # normalisation below mirrors SonarQube's debt-RATIO approach (debt relative
      # to size) rather than absolute counts. NOTE: the knees and weights here are
      # v1 judgement-based heuristics chosen for sane, monotonic behaviour — they
      # are NOT yet calibrated against a real-world baseline corpus the way CodeScene
      # calibrates its factors; corpus calibration is deliberate future work. They
      # are pinned so the SIGNAL is deterministic and auditable; treat drift as a bug.
      GRADE_THRESHOLDS = [
        ["A", 0.90],
        ["B", 0.80],
        ["C", 0.70],
        ["D", 0.60],
        ["F", 0.0]
      ].freeze

      # ---- pinned complexity normalisation ------------------------------------
      # Health falls linearly as the MEAN per-file risk approaches a knee. Averaging
      # over files already dilutes single outliers, so a plain ratio (à la SonarQube's
      # debt ratio) is honest and predictable — no extra log compression, which would
      # double-penalise moderate code.
      COMPLEXITY_CHURN_KNEE = 300.0 # mean complexity*churn per file at which health hits the floor
      COMPLEXITY_ONLY_KNEE = 150.0  # mean summed-ABC per file at which health hits the floor (no churn signal)
      COMPLEXITY_FLOOR = 0.30       # complexity alone is a soft signal: never reads as 0.0 catastrophic

      # ---- pinned dead-code normalisation -------------------------------------
      DEADCODE_DENSITY_KNEE = 0.12   # confidence-weighted dead density at which health hits 0
      DEADCODE_UNRESOLVED_CAP = 0.95 # an unresolved index cannot certify perfect health

      # ---- pinned duplication normalisation -----------------------------------
      DUPLICATION_BURDEN_KNEE = 40.0 # confidence-weighted duplicated mass per file at which health hits 0

      # ---- pinned boundaries normalisation ------------------------------------
      BOUNDARY_BURDEN_KNEE = 4.0 # severity-weighted boundary violations per file at which health hits 0

      # One auditable observation behind a sub-score. Mirrors the rule/.../detail
      # reason shape used across Moult, but health sub-scores are RATIOS not signed
      # delta-sums, so it carries the observed +value+ (a [0, 1] quantity) rather
      # than a +delta+. Kept local so the health slice does not couple to the
      # dead-code or duplication Reason structs.
      Reason = Struct.new(:rule, :value, :detail) do
        def to_h
          {rule: rule.to_s, value: value, detail: detail}
        end
      end

      # A graded component: a health sub-score in [0, 1] (1.0 = healthy), the stats
      # backing it, and the reasons behind it.
      Component = Struct.new(:name, :category, :score, :stats, :reasons)

      # The whole-codebase (or per-file) result: the composite + the present
      # components. +score+/+grade+ are nil only when every component is absent.
      Composite = Struct.new(:score, :grade, :components)

      # IO-free numeric inputs. The orchestrator extracts one of each from the
      # matching analysis report; the model never sees a report object. A nil slot
      # means the analysis was absent or errored — it is dropped from the composite.
      Inputs = Struct.new(:complexity, :dead_code, :duplication, :coverage, :boundaries)

      ComplexityInput = Struct.new(:file_count, :total_complexity, :total_score, :churn_present)
      DeadCodeInput = Struct.new(:symbol_count, :confidence_sum, :finding_count, :resolved)
      DuplicationInput = Struct.new(:file_count, :weighted_dup_mass, :set_count)
      CoverageInput = Struct.new(:hot, :cold)
      BoundariesInput = Struct.new(:file_count, :weighted_violations, :violation_count)

      module_function

      # @param inputs [Inputs]
      # @return [Composite]
      def assess(inputs)
        components = [
          complexity_component(inputs.complexity),
          dead_code_component(inputs.dead_code),
          duplication_component(inputs.duplication),
          coverage_component(inputs.coverage),
          boundaries_component(inputs.boundaries)
        ].compact

        return Composite.new(score: nil, grade: nil, components: []) if components.empty?

        total_weight = components.sum { |c| WEIGHTS.fetch(c.name) }
        weighted = components.sum { |c| c.score * WEIGHTS.fetch(c.name) }
        overall = (weighted / total_weight).round(2)

        Composite.new(score: overall, grade: grade_for(overall), components: components)
      end

      # @param score [Float] composite in [0, 1]
      # @return [String] letter grade
      def grade_for(score)
        GRADE_THRESHOLDS.find { |(_, low)| score >= low }.first
      end

      # The renormalised share a present component carried of the composite.
      # @param name [String] component name
      # @param present_names [Array<String>] names of the components that contributed
      # @return [Float]
      def normalized_weight(name, present_names)
        total = present_names.sum { |n| WEIGHTS.fetch(n) }
        return 0.0 if total.zero?
        (WEIGHTS.fetch(name) / total).round(4)
      end

      # Convert a bounded badness ratio to a health sub-score, applying an optional
      # floor so a soft signal never reads as catastrophic 0.0.
      # @param badness [Float] in [0, 1] (clamped); higher = worse
      # @param floor [Float] lowest the sub-score may reach
      # @return [Float] rounded to 2 decimals
      def health_from_badness(badness, floor: 0.0)
        b = badness.clamp(0.0, 1.0)
        ((1.0 - b) * (1.0 - floor) + floor).clamp(0.0, 1.0).round(2)
      end

      # @param input [ComplexityInput, nil]
      # @return [Component, nil]
      def complexity_component(input)
        return nil unless input
        return healthy_by_absence("complexity", "no methods with complexity to score") if input.file_count.to_i.zero?

        if input.churn_present
          mean_risk = input.total_score / input.file_count.to_f
          badness = mean_risk / COMPLEXITY_CHURN_KNEE
          reason = Reason.new(rule: :complexity_churn_density, value: nil,
            detail: "mean complexity*churn per file #{mean_risk.round(1)} vs knee #{COMPLEXITY_CHURN_KNEE}")
        else
          mean_cx = input.total_complexity / input.file_count.to_f
          badness = mean_cx / COMPLEXITY_ONLY_KNEE
          reason = Reason.new(rule: :complexity_only_density, value: nil,
            detail: "no churn signal; mean ABC per file #{mean_cx.round(1)} vs knee #{COMPLEXITY_ONLY_KNEE}")
        end

        score = health_from_badness(badness, floor: COMPLEXITY_FLOOR)
        reason.value = score
        Component.new(
          name: "complexity", category: "complexity", score: score,
          stats: {
            file_count: input.file_count,
            mean_complexity: (input.total_complexity / input.file_count.to_f).round(2),
            churn_present: input.churn_present
          },
          reasons: [reason]
        )
      end

      # @param input [DeadCodeInput, nil]
      # @return [Component, nil]
      def dead_code_component(input)
        return nil unless input
        return healthy_by_absence("dead_code", "no symbols to score") if input.symbol_count.to_i.zero?

        density = input.confidence_sum / input.symbol_count.to_f
        score = health_from_badness(density / DEADCODE_DENSITY_KNEE)
        reasons = [Reason.new(rule: :dead_density, value: score,
          detail: "confidence-weighted dead density #{density.round(4)} vs knee #{DEADCODE_DENSITY_KNEE} " \
                  "(#{input.finding_count} candidates / #{input.symbol_count} symbols)")]

        unless input.resolved
          capped = [score, DEADCODE_UNRESOLVED_CAP].min
          if capped < score
            score = capped
            reasons << Reason.new(rule: :index_unresolved, value: score,
              detail: "index did not fully resolve; capped at #{DEADCODE_UNRESOLVED_CAP}")
          end
        end

        Component.new(
          name: "dead_code", category: "dead_code", score: score,
          stats: {
            symbol_count: input.symbol_count,
            candidate_count: input.finding_count,
            confidence_sum: input.confidence_sum.round(2),
            resolved: input.resolved
          },
          reasons: reasons
        )
      end

      # @param input [DuplicationInput, nil]
      # @return [Component, nil]
      def duplication_component(input)
        return nil unless input
        return healthy_by_absence("duplication", "no files to score") if input.file_count.to_i.zero?

        burden = input.weighted_dup_mass / input.file_count.to_f
        score = health_from_badness(burden / DUPLICATION_BURDEN_KNEE)
        Component.new(
          name: "duplication", category: "duplication", score: score,
          stats: {
            file_count: input.file_count,
            weighted_dup_mass: input.weighted_dup_mass.round(1),
            clone_sets: input.set_count
          },
          reasons: [Reason.new(rule: :duplication_burden, value: score,
            detail: "confidence-weighted duplicated mass per file #{burden.round(2)} vs knee #{DUPLICATION_BURDEN_KNEE} " \
                    "(#{input.set_count} clone sets)")]
        )
      end

      # @param input [CoverageInput, nil]
      # @return [Component, nil]
      def coverage_component(input)
        return nil unless input
        tracked = input.hot.to_i + input.cold.to_i
        # untracked is deliberately NOT in the denominator: it is no signal, so it
        # must never count as either healthy or unhealthy.
        return healthy_by_absence("coverage", "no tracked symbols (untracked carries no signal)") if tracked.zero?

        cold_ratio = input.cold / tracked.to_f
        score = health_from_badness(cold_ratio)
        Component.new(
          name: "coverage", category: "coverage", score: score,
          stats: {hot: input.hot, cold: input.cold, tracked: tracked},
          reasons: [Reason.new(rule: :cold_ratio, value: score,
            detail: "#{input.cold} cold of #{tracked} tracked symbols (untracked excluded)")]
        )
      end

      # @param input [BoundariesInput, nil]
      # @return [Component, nil]
      def boundaries_component(input)
        return nil unless input
        return healthy_by_absence("boundaries", "no files to score") if input.file_count.to_i.zero?

        burden = input.weighted_violations / input.file_count.to_f
        score = health_from_badness(burden / BOUNDARY_BURDEN_KNEE)
        Component.new(
          name: "boundaries", category: "architecture_boundary", score: score,
          stats: {
            file_count: input.file_count,
            weighted_violations: input.weighted_violations.round(2),
            violation_count: input.violation_count
          },
          reasons: [Reason.new(rule: :boundary_burden, value: score,
            detail: "severity-weighted boundary violations per file #{burden.round(3)} vs knee #{BOUNDARY_BURDEN_KNEE} " \
                    "(#{input.violation_count} violations)")]
        )
      end

      # A present component that is vacuously healthy because it had nothing to
      # score — distinct from an absent (nil) component, and it says why.
      def healthy_by_absence(name, detail)
        Component.new(
          name: name, category: name, score: 1.0, stats: {},
          reasons: [Reason.new(rule: :no_signal, value: 1.0, detail: detail)]
        )
      end
    end
  end
end
