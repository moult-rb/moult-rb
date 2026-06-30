# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # The gate's machine contract: a thin pass-through over {GateReport#to_h},
    # validated against schema/gate.schema.json. Renders from the same report as
    # every other gate formatter so they cannot drift.
    module GateJson
      module_function

      # @param report [GateReport]
      # @return [String]
      def render(report)
        JSON.pretty_generate(report.to_h)
      end
    end
  end
end
