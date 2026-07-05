# frozen_string_literal: true

module Moult
  module Formatters
    # Human-readable table of circular file dependencies. Renders from the same
    # {CyclesReport} as the JSON formatter so the two cannot disagree. Sorting
    # already happened in {Cycles}; this layer owns column formatting only.
    module CyclesTable
      MAX_FILES = 3
      RIGHT_ALIGNED = [0, 1].freeze # CONF, SIZE

      module_function

      # @param report [CyclesReport]
      # @return [String]
      def render(report)
        findings = report.findings
        return "No cycles found." if findings.empty?

        headers = %w[CONF SIZE CYCLE FILES]
        rows = findings.map { |f| row(f) }
        [heading(findings.size), "", TextTable.render(headers, rows, right_aligned: RIGHT_ALIGNED)].join("\n")
      end

      def heading(count)
        "Circular file dependencies (constant-resolved): #{count} cycles"
      end

      def row(finding)
        [
          format("%.2f", finding.confidence),
          finding.size.to_s,
          finding.cycle_group,
          chain(finding.files)
        ]
      end

      # "a.rb -> b.rb -> a.rb" for small cycles; "a.rb -> b.rb -> c.rb (+2 more)"
      # once the membership no longer fits.
      def chain(files)
        shown = files.first(MAX_FILES)
        extra = files.size - shown.size
        return "#{shown.join(" -> ")} (+#{extra} more)" if extra.positive?
        "#{shown.join(" -> ")} -> #{files.first}"
      end
    end
  end
end
