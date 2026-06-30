# frozen_string_literal: true

require_relative "git"

module Moult
  # Per-file change frequency from git history. "Change" means a commit that
  # touched the file; the count is the number of such commits within the window.
  #
  # Decisions (v0.1):
  #   * Window: the last 12 months by default ({DEFAULT_SINCE}), configurable via
  #     +since+ (anything `git log --since` accepts, e.g. "2025-01-01"). All of
  #     history over-weights long-lived files, so we bound it.
  #   * Renames are NOT followed. `git log --follow` only works for a single
  #     pathspec, so whole-repo rename tracking is out of scope; a renamed file
  #     starts a fresh count under its new path.
  #   * Outside a git repository, churn is empty (every file scores 0).
  #
  # Paths are reported relative to the repository root, as git emits them.
  module Churn
    DEFAULT_SINCE = "12 months ago"

    module_function

    # @param root [String] directory to run git in
    # @param since [String] git --since boundary
    # @return [Hash{String=>Integer}] path => commit count (default 0)
    def collect(root:, since: DEFAULT_SINCE)
      output = Git.log_name_only(root, since: since)
      return empty_counts unless output

      parse(output)
    end

    # Pure parser over `git log --name-only --pretty=format:` output. Counts how
    # many lines (commits) mention each path.
    # @param output [String]
    # @return [Hash{String=>Integer}]
    def parse(output)
      counts = empty_counts
      output.each_line(chomp: true) do |line|
        next if line.empty?

        counts[line] += 1
      end
      counts
    end

    def empty_counts
      Hash.new(0)
    end
  end
end
