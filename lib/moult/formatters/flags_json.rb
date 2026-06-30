# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # JSON rendering of a {FlagsReport}. A thin pass-through of the report's own
    # +to_h+ so the serialized shape cannot drift from the table formatter or the
    # contract.
    module FlagsJson
      module_function

      # @param report [FlagsReport]
      # @return [String]
      def render(report)
        JSON.pretty_generate(report.to_h)
      end
    end
  end
end
