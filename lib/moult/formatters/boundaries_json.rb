# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # JSON rendering of a {BoundariesReport}. A thin pass-through of the report's own
    # +to_h+ so the serialized shape cannot drift from the table formatter or the
    # contract.
    module BoundariesJson
      module_function

      # @param report [BoundariesReport]
      # @return [String]
      def render(report)
        JSON.pretty_generate(report.to_h)
      end
    end
  end
end
