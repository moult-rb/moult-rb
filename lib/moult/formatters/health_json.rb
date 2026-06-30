# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # Emits the typed health JSON contract (schema/health.schema.json). Renders
    # straight from {HealthReport#to_h} so the serialized shape cannot drift from
    # the result model.
    module HealthJson
      module_function

      # @param report [HealthReport]
      # @return [String] pretty-printed JSON
      def render(report)
        JSON.pretty_generate(report.to_h)
      end
    end
  end
end
