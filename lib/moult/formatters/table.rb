# frozen_string_literal: true

module Moult
  module Formatters
    # Human-readable ranked table. Renders from the same {Report} as the JSON
    # formatter, so the two cannot disagree. Sorting already happened in
    # {Scoring}; this layer owns limiting and column formatting only.
    module Table
      HEADERS = ["#", "SCORE", "COMPLEXITY", "CHURN", "IN", "OUT", "INST", "FILE", "WORST METHOD"].freeze
      # Right-align the numeric columns; left-align file and method.
      RIGHT_ALIGNED = [0, 1, 2, 3, 4, 5, 6].freeze
      GUTTER = "  "

      module_function

      # @param report [Report]
      # @param limit [Integer, nil] show only the top N hotspots
      # @return [String]
      def render(report, limit: nil)
        hotspots = report.hotspots
        hotspots = hotspots.first(limit) if limit
        return "No hotspots found." if hotspots.empty?

        rows = hotspots.each_with_index.map { |h, i| row(h, i + 1) }
        [heading(report, hotspots.size), "", table(rows)].join("\n")
      end

      def heading(report, shown)
        total = report.hotspots.size
        scope = (shown < total) ? "top #{shown} of #{total}" : total.to_s
        window = report.churn_window ? " — churn over #{report.churn_window}" : ""
        "Hotspots (complexity x churn): #{scope} files#{window}"
      end

      def row(hotspot, rank)
        worst = hotspot.worst_method
        worst_cell = worst ? "#{worst.name} (#{num(worst.abc)})" : "-"
        [
          rank.to_s,
          num(hotspot.score),
          num(hotspot.complexity),
          hotspot.churn.to_s,
          hotspot.fan_in ? hotspot.fan_in.to_s : "-",
          hotspot.fan_out ? hotspot.fan_out.to_s : "-",
          hotspot.instability ? format("%.2f", hotspot.instability) : "-",
          hotspot.path,
          worst_cell
        ]
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
        cells.each_with_index.map { |cell, col|
          RIGHT_ALIGNED.include?(col) ? cell.rjust(widths[col]) : cell.ljust(widths[col])
        }.join(GUTTER).rstrip
      end

      def num(value)
        format("%.1f", value)
      end
    end
  end
end
