# frozen_string_literal: true

module Moult
  module Formatters
    # Shared plumbing for the header + rows text tables every analysis formatter
    # renders. Extracted so the column-width/alignment logic lives in exactly one
    # place instead of being copied into each `*_table` formatter (the gate caught
    # that duplication when run on Moult itself).
    #
    # Columns left-align by default; pass the 0-based indices to right-align (e.g.
    # numeric columns) in +right_aligned+.
    module TextTable
      GUTTER = "  "

      module_function

      # @param headers [Array<String>]
      # @param rows [Array<Array<String>>]
      # @param right_aligned [Array<Integer>] 0-based column indices to right-align
      # @return [String] the header row followed by each data row, newline-joined
      def render(headers, rows, right_aligned: [])
        widths = column_widths(headers, rows)
        ([headers] + rows).map { |cells| format_row(cells, widths, right_aligned) }.join("\n")
      end

      def column_widths(headers, rows)
        headers.each_index.map do |col|
          ([headers[col]] + rows.map { |r| r[col] }).map(&:length).max
        end
      end

      def format_row(cells, widths, right_aligned)
        cells.each_with_index.map { |cell, col|
          right_aligned.include?(col) ? cell.rjust(widths[col]) : cell.ljust(widths[col])
        }.join(GUTTER).rstrip
      end
    end
  end
end
