# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # Emits the typed dead-code JSON contract (schema/deadcode.schema.json).
    # Renders straight from {DeadCodeReport#to_h} so the serialized shape cannot
    # drift from the result model.
    module DeadCodeJson
      module_function

      # @param report [DeadCodeReport]
      # @return [String] pretty-printed JSON
      def render(report)
        JSON.pretty_generate(report.to_h)
      end
    end
  end
end
