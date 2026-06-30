# frozen_string_literal: true

require "pathname"

module Moult
  # Builds the stable symbol id used as the cross-analysis join key:
  # "<path>:<start_line>:<fqname>" (path relative to the analysis root,
  # start_line 1-based). Shared by {Scoring} (hotspots) and {Index} (dead code)
  # so the two analyses mint identical ids for the same definition and the
  # Phase 3 coverage merge can join them. Centralised here so the format cannot
  # drift between producers.
  module SymbolId
    module_function

    # @param path [String] path relative to the analysis root
    # @param start_line [Integer] 1-based definition line
    # @param fqname [String] fully-qualified lexical name (Class#method / Class.method)
    # @return [String]
    def for(path:, start_line:, fqname:)
      "#{path}:#{start_line}:#{fqname}"
    end

    # @param abs [String] absolute path
    # @param root [String] absolute analysis root
    # @return [String] path relative to root
    def relative_path(abs, root)
      Pathname.new(abs).relative_path_from(Pathname.new(root)).to_s
    end
  end
end
