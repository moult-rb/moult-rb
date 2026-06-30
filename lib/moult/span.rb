# frozen_string_literal: true

module Moult
  # A source location range for a definition. Lines are 1-based, columns are
  # 0-based, matching Prism's location offsets. Part of the protected JSON
  # contract and a component of a method's Phase 3 coverage join key.
  Span = Struct.new(:start_line, :start_column, :end_line, :end_column) do
    def to_h
      {
        start_line: start_line,
        start_column: start_column,
        end_line: end_line,
        end_column: end_column
      }
    end
  end
end
