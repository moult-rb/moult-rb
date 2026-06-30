# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # Emits the typed duplication JSON contract (schema/duplication.schema.json).
    # Renders straight from {DuplicationReport#to_h} so the serialized shape cannot
    # drift from the result model.
    module DuplicationJson
      module_function

      # @param report [DuplicationReport]
      # @return [String] pretty-printed JSON
      def render(report)
        JSON.pretty_generate(report.to_h)
      end
    end
  end
end
