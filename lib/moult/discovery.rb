# frozen_string_literal: true

require_relative "git"

module Moult
  # Finds the Ruby files to analyse under a root directory.
  #
  # Inside a git repository we use `git ls-files` so .gitignore is respected for
  # free (vendored and generated code is excluded as the repo intends).
  # Otherwise we glob, explicitly skipping the usual non-source directories.
  module Discovery
    SKIP_DIRS = %w[vendor tmp node_modules .git].freeze

    module_function

    # @param root [String] absolute directory to search
    # @return [Array<String>] absolute paths to .rb files, sorted
    def ruby_files(root)
      files = Git.repo?(root) ? from_git(root) : from_glob(root)
      files.sort
    end

    def from_git(root)
      Git.listed_files(root)
        .select { |rel| rel.end_with?(".rb") }
        .map { |rel| File.join(root, rel) }
    end

    def from_glob(root)
      Dir.glob(File.join(root, "**", "*.rb")).reject { |abs| skip?(abs, root) }
    end

    def skip?(abs, root)
      relative = abs.delete_prefix(root).delete_prefix(File::SEPARATOR)
      relative.split(File::SEPARATOR).any? { |segment| SKIP_DIRS.include?(segment) }
    end
  end
end
