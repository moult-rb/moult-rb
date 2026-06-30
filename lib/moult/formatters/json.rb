# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # Emits the typed JSON output contract (schema/hotspots.schema.json). Renders
    # straight from {Report#to_h}; only presentation concerns (limiting) live
    # here, so the serialized shape can never drift from the result model.
    module Json
      module_function

      # @param report [Report]
      # @param limit [Integer, nil] keep only the top N hotspots
      # @return [String] pretty-printed JSON
      def render(report, limit: nil)
        data = report.to_h
        data[:hotspots] = data[:hotspots].first(limit) if limit
        JSON.pretty_generate(data)
      end
    end
  end
end
