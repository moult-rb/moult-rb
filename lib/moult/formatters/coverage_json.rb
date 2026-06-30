# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # Emits the typed coverage-map JSON contract (schema/coverage.schema.json),
    # straight from {CoverageReport#to_h} so the serialized shape cannot drift.
    module CoverageJson
      module_function

      # @param report [CoverageReport]
      # @return [String] pretty-printed JSON
      def render(report)
        JSON.pretty_generate(report.to_h)
      end
    end
  end
end
