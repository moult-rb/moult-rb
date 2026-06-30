# frozen_string_literal: true

module Moult
  module Formatters
    # Human-readable table of architecture-boundary violations. Renders from the same
    # {BoundariesReport} as the JSON formatter so the two cannot disagree. Sorting
    # already happened in {Boundaries}; this layer owns column formatting only.
    #
    # The heading is deliberate: these are recorded packwerk violations, classified
    # by severity — never a claim that the code is certainly wrong.
    module BoundariesTable
      MAX_FILES = 3

      module_function

      # @param report [BoundariesReport]
      # @return [String]
      def render(report)
        return "Not a packwerk project (no packwerk.yml): no architecture boundaries to check." unless report.configured

        findings = report.findings
        return "No architecture-boundary violations recorded." if findings.empty?

        headers = %w[SEV TYPE REFERENCING DEFINING CONSTANT FILES]
        rows = findings.map { |f| row(f) }
        [heading(report.summary), "", TextTable.render(headers, rows)].join("\n")
      end

      def heading(summary)
        by_sev = %w[high medium low].filter_map { |s| "#{summary[:by_severity][s]} #{s}" if summary[:by_severity][s].to_i.positive? }
        "Architecture-boundary violations (packwerk, recorded — not certainties): " \
          "#{summary[:findings]} groups, #{summary[:violations]} violations (#{by_sev.join(", ")})"
      end

      def row(finding)
        [
          finding.severity,
          finding.violation_type,
          finding.referencing_package,
          finding.defining_package,
          finding.constant,
          files(finding.occurrences)
        ]
      end

      def files(occurrences)
        shown = occurrences.first(MAX_FILES).map(&:path)
        extra = occurrences.size - shown.size
        extra.positive? ? "#{shown.join(", ")} (+#{extra} more)" : shown.join(", ")
      end
    end
  end
end
