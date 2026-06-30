# frozen_string_literal: true

module Moult
  module Formatters
    # Human-readable table of duplication candidates. Renders from the same
    # {DuplicationReport} as the JSON formatter so the two cannot disagree.
    # Sorting already happened in {Duplication}; this layer owns column
    # formatting only.
    #
    # The heading is deliberate: these are confidence-graded candidates, never
    # certainties.
    module DuplicationTable
      MAX_LOCATIONS = 3
      RIGHT_ALIGNED = [0, 2, 4].freeze # CONF, MASS, COUNT

      module_function

      # @param report [DuplicationReport]
      # @return [String]
      def render(report)
        findings = report.findings
        return "No duplication found." if findings.empty?

        headers = %w[CONF KIND MASS NODE COUNT LOCATIONS]
        rows = findings.map { |f| row(f) }
        [heading(findings.size), "", TextTable.render(headers, rows, right_aligned: RIGHT_ALIGNED)].join("\n")
      end

      def heading(count)
        "Duplication candidates (confidence-graded — not certainties): #{count} clone sets"
      end

      def row(finding)
        [
          conf(finding.confidence),
          finding.kind.to_s,
          finding.mass.to_s,
          finding.node_type,
          finding.occurrences.size.to_s,
          locations(finding.occurrences)
        ]
      end

      def locations(occurrences)
        shown = occurrences.first(MAX_LOCATIONS).map { |o| "#{o.path}:#{o.line}" }
        extra = occurrences.size - shown.size
        extra.positive? ? "#{shown.join(", ")} (+#{extra} more)" : shown.join(", ")
      end

      def conf(value)
        format("%.2f", value)
      end
    end
  end
end
