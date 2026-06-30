# frozen_string_literal: true

module Moult
  # The serialized result model for `moult gate` (schema/gate.schema.json), sibling
  # to {HealthReport} and {BoundariesReport}. It owns its own JSON envelope and
  # leaves every signal contract — and the two protected APIs — untouched.
  #
  # This is the FIRST and ONLY Moult contract that renders a VERDICT. Every other
  # analysis emits a confidence-graded / classified SIGNAL with no pass/fail; the
  # gate consumes those signals, applies an explicit recorded {Gate::Policy}, and
  # reports one top-level verdict. The verdict is an auditable application of that
  # policy over confidence-graded candidates — never a claim that code is certainly
  # wrong or dead. The words "verdict"/"pass"/"fail" live here and nowhere else.
  class GateReport
    # Bump only on a breaking change to the serialized shape.
    SCHEMA_VERSION = 1

    # Provenance for one signal analysis the gate composed: did it contribute, and
    # if not, why (errored, or not applicable — e.g. a non-packwerk repo).
    Component = Struct.new(:name, :present, :diagnostic) do
      def to_h
        {name: name, present: present, diagnostic: diagnostic}
      end
    end

    attr_reader :root, :git_ref, :generated_at, :base_ref, :merge_base, :scope,
      :components, :policy, :evaluation

    # @param root [String] absolute analysis root
    # @param base_ref [String, nil] requested base ref (nil under :all scope)
    # @param merge_base [String, nil] resolved merge-base sha (nil under :all scope)
    # @param scope [Symbol] :diff or :all
    # @param components [Array<Component>] which signal analyses ran/were skipped
    # @param policy [Gate::Policy] the applied policy (recorded in full)
    # @param evaluation [Gate::Evaluation::Verdict] verdict + per-rule outcomes
    def initialize(root:, base_ref:, merge_base:, scope:, components:, policy:, evaluation:,
      git_ref: nil, generated_at: nil)
      @root = root
      @base_ref = base_ref
      @merge_base = merge_base
      @scope = scope
      @components = components
      @policy = policy
      @evaluation = evaluation
      @git_ref = git_ref
      @generated_at = generated_at
    end

    # The top-level verdict, "pass" or "fail". The CLI maps this to its exit code.
    def verdict
      evaluation.verdict
    end

    def rules
      evaluation.rules
    end

    def reasons
      evaluation.reasons
    end

    # Contributing findings flattened across all rules (for CI projections).
    def findings
      rules.flat_map(&:findings)
    end

    def summary
      {
        rules: rules.size,
        evaluated: rules.count(&:evaluated),
        failed: rules.count { |r| r.evaluated && r.passed == false },
        findings: findings.size
      }
    end

    def to_h
      {
        schema_version: SCHEMA_VERSION,
        tool: {name: "moult", version: Moult::VERSION},
        analysis: {
          root: root,
          git_ref: git_ref,
          generated_at: generated_at,
          base_ref: base_ref,
          merge_base: merge_base,
          scope: scope.to_s,
          components: components.map(&:to_h)
        },
        policy: policy.to_h,
        verdict: verdict,
        reasons: reasons.map(&:to_h),
        summary: summary,
        rules: rules.map(&:to_h)
      }
    end
  end
end
