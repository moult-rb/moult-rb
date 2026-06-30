# frozen_string_literal: true

module Moult
  # A Moult-owned value object describing what changed between a base ref and the
  # working tree, plus the pure filter the gate uses to decide whether a finding
  # is "in the diff". This is the genuinely novel component of the PR gate — it is
  # pinned against hand-built git output exactly like the coverage {Resolver} and
  # the ABC metric; drift is a bug.
  #
  # {Git} is the only file that shells git; it hands this class raw
  # `--name-status` and `--unified=0` text. {parse} turns that text into a Diff
  # with no IO, so it is trivially unit-testable. {compute} is the thin IO wrapper
  # that calls git then {parse}.
  #
  # Line ranges are taken from the NEW side of each `--unified=0` hunk header
  # (`@@ -a,b +c,d @@`): with zero context they are precisely the added/changed
  # lines. Paths are repo-root-relative (git's own framing); the gate is meant to
  # run at the repository root, where they line up with Moult's root-relative
  # finding paths.
  class Diff
    # One changed file. +status+ is git's single-letter code (A/M/D/R/C/...);
    # +line_ranges+ are the new-side changed line ranges (empty for a deletion, a
    # pure-deletion hunk, or a content-less rename).
    ChangedFile = Struct.new(:path, :status, :line_ranges) do
      # Does +line+ fall on a changed/added line of this file?
      def changed_line?(line)
        line_ranges.any? { |r| r.cover?(line) }
      end

      # Does the inclusive line range [lo, hi] intersect any changed range?
      def changed_range?(lo, hi)
        line_ranges.any? { |r| r.begin <= hi && r.end >= lo }
      end
    end

    attr_reader :base_ref, :merge_base, :scope, :files

    # @param base_ref [String, nil] the requested base ref (nil for :all scope)
    # @param merge_base [String, nil] resolved merge-base sha (nil for :all scope)
    # @param scope [Symbol] :diff (gate the changed lines) or :all (gate everything)
    # @param files [Array<ChangedFile>]
    def initialize(base_ref:, merge_base:, scope:, files:)
      @base_ref = base_ref
      @merge_base = merge_base
      @scope = scope
      @files = files
      @by_path = files.to_h { |f| [f.path, f] }
    end

    # Line-level membership: is the span [start_line, end_line] inside the diff?
    # Used where an analysis has lines (complexity methods, dead-code spans,
    # duplication/flag occurrences). With +start_line+ nil this falls back to
    # path-level. Always true under :all scope.
    # @return [Boolean]
    def in_diff?(path:, start_line: nil, end_line: nil)
      return true if scope == :all
      return includes_path?(path) if start_line.nil?

      file = @by_path[path]
      return false unless file

      file.changed_range?(start_line, end_line || start_line)
    end

    # Path-level membership: did this file change at all? The fallback where an
    # analysis is file-keyed with no line numbers (boundaries — null symbol_id).
    # Always true under :all scope.
    # @return [Boolean]
    def includes_path?(path)
      return true if scope == :all

      @by_path.key?(path)
    end

    class << self
      # Build a Diff from raw git text. PURE — no IO. Pinned in test/test_diff.rb.
      # @param name_status [String] `git diff --name-status REF` output
      # @param unified_diff [String] `git diff --unified=0 REF` output
      # @return [Diff]
      def parse(name_status:, unified_diff:, base_ref:, merge_base:, scope: :diff)
        ranges = parse_unified(utf8(unified_diff))
        files = parse_name_status(utf8(name_status)).map do |path, status|
          ChangedFile.new(path: path, status: status, line_ranges: ranges[path] || [])
        end
        new(base_ref: base_ref, merge_base: merge_base, scope: scope, files: files)
      end

      # Resolve the diff for +root+ against +base_ref+ via {Git}, then {parse}.
      # @param scope [Symbol] :diff or :all (:all yields an all-inclusive Diff)
      # @raise [Moult::Error] when the merge-base cannot be resolved
      # @return [Diff]
      def compute(root:, base_ref:, scope: :diff)
        return new(base_ref: nil, merge_base: nil, scope: :all, files: []) if scope == :all

        mb = Git.merge_base(root, base_ref)
        unless mb
          raise Moult::Error,
            "could not resolve a merge-base between #{base_ref.inspect} and HEAD " \
            "(unknown ref, shallow clone, or not a git repository); " \
            "pass --base REF or --scope all"
        end

        parse(
          name_status: Git.diff_name_status(root, mb) || "",
          unified_diff: Git.diff_unified_zero(root, mb) || "",
          base_ref: base_ref,
          merge_base: mb,
          scope: :diff
        )
      end

      private

      # git emits UTF-8; reinterpret as such (scrubbing any stray bytes) so string
      # ops never raise "invalid byte sequence" under a non-UTF-8 locale, where
      # Open3 tags git's output with the ASCII default external encoding.
      def utf8(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      # path => [Range, ...] of new-side changed lines, from `--unified=0` hunks.
      def parse_unified(text)
        ranges = Hash.new { |h, k| h[k] = [] }
        current = nil
        text.each_line do |raw|
          line = raw.chomp
          if line.start_with?("+++ ")
            current = strip_diff_prefix(line[4..])
          elsif current && line.start_with?("@@")
            range = hunk_new_range(line)
            ranges[current] << range if range
          end
        end
        ranges.default_proc = nil
        ranges
      end

      # "@@ -a,b +c,d @@" -> (c..c+d-1); d defaults to 1; d==0 (deletion) -> nil.
      def hunk_new_range(header)
        m = header.match(/\+(\d+)(?:,(\d+))?/)
        return nil unless m

        start = m[1].to_i
        count = m[2] ? m[2].to_i : 1
        return nil if count.zero?

        start..(start + count - 1)
      end

      # Strip the "b/" (or "a/") prefix git puts on diff paths; drop a trailing
      # tab metadata field; nil for /dev/null (added/deleted side).
      def strip_diff_prefix(path)
        path = path.split("\t", 2).first.to_s
        # git emits the literal "/dev/null" marker for an absent side on every
        # platform; this is git's convention, not the OS null device (File::NULL
        # would wrongly be "NUL" on Windows), so match the literal.
        return nil if path == "/dev/null" # standard:disable Style/FileNull

        path.sub(%r{\A[ab]/}, "")
      end

      # "<status>\t<path>" lines -> [[path, status_code], ...]. Renames/copies
      # ("R100\told\tnew") resolve to the NEW path.
      def parse_name_status(text)
        text.each_line.filter_map do |raw|
          line = raw.chomp
          next if line.empty?

          fields = line.split("\t")
          code = fields[0].to_s[0]
          path = (code == "R" || code == "C") ? fields[2] : fields[1]
          [path, code] if path
        end
      end
    end
  end
end
