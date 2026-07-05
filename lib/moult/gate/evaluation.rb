# frozen_string_literal: true

module Moult
  module Gate
    # The pure verdict engine: given already-scoped observations and a {Policy},
    # it decides each rule's outcome and the single top-level verdict. No IO, no
    # git, no analysis objects — just the policy applied to hand-buildable facts —
    # so it is pinned in test/test_gate_policy.rb. Drift is a bug.
    #
    # The verdict is an auditable APPLICATION of a recorded policy over
    # confidence-graded candidates; it never claims code is certainly wrong or
    # dead. A rule whose backing analysis didn't run is marked `evaluated: false`
    # and never fails the gate (a broken tool is a tool-error concern, surfaced by
    # the CLI exit code, not a policy violation).
    module Evaluation
      SEVERITY_SCALE = Boundaries::Severity::SCALE

      # ---- observation inputs (one row per scoped finding) ----------------------
      DeadCodeObs = Struct.new(:symbol_id, :path, :line, :confidence)
      BoundaryObs = Struct.new(:symbol_id, :path, :line, :severity, :violation_type)
      ComplexityObs = Struct.new(:symbol_id, :path, :line, :abc)
      DuplicationObs = Struct.new(:symbol_id, :path, :line, :mass, :clone_group)

      # The full input. Each analysis's list is nil when that analysis was skipped
      # (errored, or not applicable — e.g. a non-packwerk repo for boundaries);
      # +diagnostics+ maps a skipped analysis to its reason.
      Observations = Struct.new(:dead_code, :boundaries, :complexity, :duplication, :diagnostics) do
        def initialize(dead_code: nil, boundaries: nil, complexity: nil, duplication: nil, diagnostics: {})
          super
        end
      end

      # ---- output ---------------------------------------------------------------
      Reason = Struct.new(:rule, :detail) do
        def to_h
          {rule: rule.to_s, detail: detail}
        end
      end

      # One contributing finding behind a rule outcome. Stays confidence-graded:
      # +value+ is the observed signal (confidence/abc/mass/severity), never a
      # claim of certainty. +clone_group+ links occurrences of the same clone
      # group ("<kind>:<structural-hash>"); null outside duplication.
      Contribution = Struct.new(:category, :path, :symbol_id, :line, :value, :clone_group) do
        def to_h
          {category: category, path: path, symbol_id: symbol_id, line: line, value: value, clone_group: clone_group}
        end
      end

      RuleOutcome = Struct.new(:rule, :evaluated, :observed, :threshold, :passed, :reasons, :findings) do
        def to_h
          {
            rule: rule,
            evaluated: evaluated,
            observed: observed,
            threshold: threshold,
            passed: passed,
            reasons: reasons.map(&:to_h),
            findings: findings.map(&:to_h)
          }
        end
      end

      Verdict = Struct.new(:verdict, :reasons, :rules)

      module_function

      # @param observations [Observations]
      # @param policy [Policy]
      # @return [Verdict]
      def evaluate(observations:, policy:)
        diags = observations.diagnostics || {}
        rules = [
          dead_code_rule(observations.dead_code, policy, diags[:dead_code]),
          boundary_rule(observations.boundaries, policy, diags[:boundaries]),
          complexity_rule(observations.complexity, policy, diags[:complexity]),
          duplication_rule(observations.duplication, policy, diags[:duplication])
        ]

        failed = rules.select { |r| r.evaluated && r.passed == false }
        verdict = failed.empty? ? "pass" : "fail"
        Verdict.new(verdict: verdict, reasons: verdict_reasons(verdict, failed), rules: rules)
      end

      # ---- rules ----------------------------------------------------------------
      #
      # Each rule names the threshold and the genuinely varying bits — which
      # observations violate it, the worst observed value, the per-finding value,
      # and a noun phrase for the detail — and hands them to {outcome}, which owns
      # the shared RuleOutcome construction.

      def dead_code_rule(obs, policy, diagnostic)
        t = policy.dead_code_max_confidence
        outcome("no_new_dead_code", "< #{t}", obs, diagnostic, "dead_code") do |list|
          violating = list.select { |o| o.confidence >= t }
          detail = phrase(violating, "no new dead-code candidate reaches confidence #{t} on changed lines",
            "new dead-code candidate(s) at or above confidence #{t} on changed lines")
          [violating, list.map(&:confidence).max, detail, ->(o) { o.confidence }]
        end
      end

      def boundary_rule(obs, policy, diagnostic)
        t = policy.boundary_max_severity
        ti = SEVERITY_SCALE.index(t) || 0
        outcome("no_new_high_severity_boundary", "<= #{t}", obs, diagnostic, "architecture_boundary") do |list|
          violating = list.select { |o| (SEVERITY_SCALE.index(o.severity) || 0) > ti }
          detail = phrase(violating, "no new boundary violation exceeds #{t} severity in changed files",
            "new boundary violation(s) above #{t} severity in changed files")
          [violating, list.map(&:severity).max_by { |s| SEVERITY_SCALE.index(s) || -1 }, detail, ->(o) { o.severity }]
        end
      end

      def complexity_rule(obs, policy, diagnostic)
        t = policy.complexity_ceiling
        outcome("new_code_complexity_ceiling", "<= #{t}", obs, diagnostic, "complexity") do |list|
          violating = list.select { |o| o.abc > t }
          detail = phrase(violating, "no changed method exceeds ABC complexity #{t}",
            "changed method(s) exceed ABC complexity #{t}")
          [violating, list.map(&:abc).max, detail, ->(o) { o.abc }]
        end
      end

      def duplication_rule(obs, policy, diagnostic)
        t = policy.duplication_max_mass
        outcome("new_code_duplication_ceiling", "<= #{t}", obs, diagnostic, "structural_duplication") do |list|
          violating = list.select { |o| o.mass > t }
          # Observations are per occurrence, but the reason still counts GROUPS.
          detail = phrase(violating, "no clone group touching the diff exceeds mass #{t}",
            "clone group(s) touching the diff exceed mass #{t}",
            count: violating.map(&:clone_group).uniq.size)
          [violating, list.map(&:mass).max, detail, ->(o) { o.mass }]
        end
      end

      # ---- shared construction --------------------------------------------------

      # Build a rule's outcome. The block, given the (non-nil) observation list,
      # returns [violating, observed, detail, value_extractor]; a nil list means the
      # backing analysis was skipped, so the rule is not evaluated and cannot fail.
      def outcome(rule, threshold, obs, diagnostic, category)
        return skipped(rule, threshold, diagnostic) if obs.nil?

        violating, observed, detail, value = yield(obs)
        RuleOutcome.new(
          rule: rule, evaluated: true, observed: observed, threshold: threshold,
          passed: violating.empty?,
          reasons: [Reason.new(rule: rule.to_sym, detail: detail)],
          findings: violating.map { |o| Contribution.new(category: category, path: o.path, symbol_id: o.symbol_id, line: o.line, value: value.call(o), clone_group: (o.clone_group if o.respond_to?(:clone_group))) }
        )
      end

      def skipped(rule, threshold, diagnostic)
        RuleOutcome.new(
          rule: rule, evaluated: false,
          observed: nil, threshold: threshold, passed: nil,
          reasons: [Reason.new(rule: :skipped, detail: diagnostic || "backing analysis did not run; rule not evaluated")],
          findings: []
        )
      end

      # "no X ..." when nothing violates, "<n> X ..." otherwise. +count+ overrides
      # the rendered n where one violation spans several observations (duplication
      # counts groups, not occurrences).
      def phrase(violating, none, some, count: violating.size)
        violating.empty? ? none : "#{count} #{some}"
      end

      def verdict_reasons(verdict, failed)
        if verdict == "pass"
          [Reason.new(rule: :clean_as_you_code, detail: "all evaluated policy rules passed on the scoped changes")]
        else
          failed.map { |r| Reason.new(rule: r.rule.to_sym, detail: r.reasons.first.detail) }
        end
      end
    end
  end
end
