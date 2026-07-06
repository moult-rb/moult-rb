# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # Emits the typed cycles JSON contract (schema/cycles.schema.json). Renders
    # straight from {CyclesReport#to_h} so the serialized shape cannot drift
    # from the result model.
    module CyclesJson
      module_function

      # @param report [CyclesReport]
      # @return [String] pretty-printed JSON
      def render(report)
        JSON.pretty_generate(report.to_h)
      end
    end
  end
end
