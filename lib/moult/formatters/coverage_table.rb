# frozen_string_literal: true

module Moult
  module Formatters
    # Human-readable runtime coverage map. Renders from the same
    # {CoverageReport} as the JSON formatter so the two cannot disagree; sorting
    # already happened in {CoverageReport.build}.
    module CoverageTable
      HEADERS = ["RUNTIME", "KIND", "SYMBOL", "LOCATION"].freeze
      GUTTER = "  "

      module_function

      # @param report [CoverageReport]
      # @return [String]
      def render(report)
        entries = report.entries
        return "No symbols found." if entries.empty?

        rows = entries.map { |e| row(e, report.root) }
        [heading(report.summary), "", table(rows)].join("\n")
      end

      def heading(summary)
        "Runtime coverage map: #{summary[:hot]} hot, #{summary[:cold]} cold, #{summary[:untracked]} untracked"
      end

      def row(entry, _root)
        [
          entry.runtime.to_s,
          entry.kind.to_s,
          entry.name.to_s,
          location(entry)
        ]
      end

      def location(entry)
        # symbol_id is "<path>:<start_line>:<fqname>"; the path:line prefix is the
        # most useful location and avoids re-deriving it.
        path, line, _ = entry.symbol_id.split(":", 3)
        "#{path}:#{line}"
      end

      def table(rows)
        widths = column_widths(rows)
        ([HEADERS] + rows).map { |cells| format_row(cells, widths) }.join("\n")
      end

      def column_widths(rows)
        HEADERS.each_index.map do |col|
          ([HEADERS[col]] + rows.map { |r| r[col] }).map(&:length).max
        end
      end

      def format_row(cells, widths)
        cells.each_with_index.map { |cell, col| cell.ljust(widths[col]) }.join(GUTTER).rstrip
      end
    end
  end
end
