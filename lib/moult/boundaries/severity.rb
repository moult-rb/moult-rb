# frozen_string_literal: true

module Moult
  module Boundaries
    # The per-finding model for architecture boundaries — this slice's realisation
    # of Moult's protected per-finding API. Unlike dead code, a packwerk violation
    # is not a probabilistic guess: packwerk resolved the constant via Zeitwerk and
    # verified it crosses a *declared* boundary, so the honest grade here is a
    # SEVERITY classification, not a confidence. We never manufacture a fake 1.0
    # confidence (which would carry no information); the finding's +confidence+ is
    # null and {classify} assigns a severity by violation kind instead.
    #
    # This keeps the humility invariant in a different register: we still never
    # overstate. A "severity" says how architecturally significant the *kind* of
    # boundary crossing is — it does not assert the code is wrong, only that
    # packwerk recorded a declared-boundary violation of that kind.
    #
    # {classify} is a pure function of the violation type — no IO, no packwerk
    # objects — so it is pinned against hand-built inputs exactly like {ABC}, the
    # coverage {Resolver}, and the duplication {Confidence} model. Drift is a bug.
    module Severity
      CATEGORY = "architecture_boundary"

      # The ordered severity scale (least → most architecturally significant).
      SCALE = %w[low medium high].freeze

      # Pinned severity per packwerk violation type. Dependency and layer crossings
      # break the *declared* dependency graph — the core architectural contract —
      # so they rank highest. Privacy/visibility/folder_privacy are reaches past a
      # package's public surface: real violations, but a narrower contract, so
      # medium. An unrecognised type degrades to +low+ (we never drop it).
      SEVERITY = {
        "dependency" => "high",
        "layer" => "high",
        "privacy" => "medium",
        "visibility" => "medium",
        "folder_privacy" => "medium"
      }.freeze

      DEFAULT_SEVERITY = "low"

      # Numeric weight per severity, consumed by the health composite to turn a set
      # of violations into a per-file badness burden. Pinned alongside SEVERITY so
      # the health boundaries component stays deterministic.
      SEVERITY_WEIGHT = {"high" => 1.0, "medium" => 0.6, "low" => 0.3}.freeze

      # One auditable note behind a classification. Mirrors the shared rule/detail
      # reason shape, but a severity is categorical (not a delta-sum), so it carries
      # no +delta+. Kept local so the boundaries slice does not couple to the
      # dead-code or duplication Reason structs.
      Reason = Struct.new(:rule, :detail) do
        def to_h
          {rule: rule.to_s, detail: detail}
        end
      end

      # The graded result: a severity on {SCALE} and the reasons behind it.
      Assessment = Struct.new(:severity, :reasons)

      module_function

      # @param violation_type [String] packwerk violation type, e.g. "dependency"
      # @return [Assessment]
      def classify(violation_type:)
        severity = SEVERITY.fetch(violation_type, DEFAULT_SEVERITY)
        Assessment.new(severity: severity, reasons: [Reason.new(rule: :"#{violation_type}_violation", detail: detail_for(violation_type, severity))])
      end

      def detail_for(violation_type, severity)
        case violation_type
        when "dependency"
          "references a constant in a package this one does not declare a dependency on (#{severity})"
        when "layer"
          "depends across a declared architecture layer boundary (#{severity})"
        when "privacy"
          "references another package's private (non-public) constant (#{severity})"
        when "visibility"
          "references a package that does not list this one as visible_to (#{severity})"
        when "folder_privacy"
          "references a nested package outside the allowed folder scope (#{severity})"
        else
          "recorded packwerk boundary violation of an unrecognised type (#{severity})"
        end
      end
    end
  end
end
