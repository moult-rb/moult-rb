# frozen_string_literal: true

require "yaml"

module Moult
  module Gate
    # Loads gate policy overrides from a project config file (.moult.yml by
    # default) and hands them to {Policy}. Config is plain YAML — psych is stdlib,
    # so the gate adds no new runtime dependency. Only the `gate:` section is read;
    # everything else is ignored, leaving room for future Moult config.
    #
    # IO lives here, never in the pure {Policy}/{Evaluation} models: this resolves
    # a path and reads a file, then defers entirely to {Policy.load}.
    module Config
      DEFAULT_FILENAME = ".moult.yml"

      module_function

      # @param root [String] absolute analysis root
      # @param config_path [String, nil] explicit --config path; nil auto-detects
      #   .moult.yml at the root
      # @return [Policy] defaults when no config is present
      # @raise [Moult::Error] when an explicit path is missing or the file is unreadable
      def policy_for(root:, config_path: nil)
        path = resolve(root, config_path)
        return Policy.default unless path

        data = YAML.safe_load_file(path) || {}
        unless data.is_a?(Hash)
          raise Moult::Error, "config #{relative(path, root)} must be a YAML mapping"
        end

        overrides = data["gate"] || data[:gate] || {}
        Policy.load(overrides, source: relative(path, root))
      rescue Psych::SyntaxError => e
        raise Moult::Error, "could not parse config #{relative(path, root)}: #{e.message}"
      end

      def resolve(root, config_path)
        if config_path
          return config_path if File.file?(config_path)

          raise Moult::Error, "no such config file: #{config_path}"
        end

        default = File.join(root, DEFAULT_FILENAME)
        File.file?(default) ? default : nil
      end

      def relative(path, root)
        SymbolId.relative_path(File.expand_path(path), root)
      end
    end
  end
end
