# frozen_string_literal: true

require "json"
require "time"
require_relative "symbol_id"

module Moult
  # Ingests line-keyed code coverage from a LOCAL FILE and normalises it into one
  # Moult-owned value object ({Dataset}) the {Resolver} can read. This is the
  # runtime-layer analogue of {Index}: external formats (SimpleCov, stdlib
  # +Coverage+) come in, only Moult types go out, so the input is swappable.
  #
  # Two on-disk formats are understood (auto-detected, or forced via +format:+):
  #
  # * +:simplecov+ — SimpleCov's +coverage/.resultset.json+:
  #   <tt>{command => {"coverage" => {abs_path => {"lines" => [...]}}, "timestamp" => epoch}}</tt>.
  #   Multiple command runs are merged element-wise.
  # * +:coverage+ — a JSON dump of stdlib <tt>Coverage.result(lines: true)</tt>:
  #   <tt>{abs_path => {"lines" => [...]}}</tt> or the legacy bare <tt>{abs_path => [...]}</tt>.
  #
  # Line arrays are 0-indexed (index 0 = line 1) with the shared convention:
  # +nil+ = non-executable, +0+ = executable but never run, +N+ = hit count.
  # +oneshot_lines+ is intentionally unsupported: it cannot distinguish 0 from
  # nil, so runtime-cold could not be detected.
  module Coverage
    module_function

    # Provenance of a merged coverage dataset. Captured into the protected
    # contract so a consumer can see where the runtime evidence came from. The
    # +collected_at+ slot also seeds a future stale-detection slice (deferred).
    Source = Struct.new(:backend, :version, :collected_at) do
      def to_h
        {backend: backend, version: version, collected_at: collected_at}
      end
    end

    # Normalised coverage: per (root-relative) path, the 0-indexed line array.
    Dataset = Struct.new(:entries, :source, :unmatched_count) do
      # @return [Boolean] whether this file appeared in the coverage dataset
      def tracked?(path)
        entries.key?(path)
      end

      # @param line [Integer] 1-based line number
      # @return [Integer, nil] coverage value at that line, or nil if untracked
      def line_value(path, line)
        arr = entries[path]
        arr && arr[line - 1]
      end
    end

    # @param path [String] path to the coverage file
    # @param root [String] absolute analysis root (findings are relative to it)
    # @param format [Symbol] :auto, :simplecov, or :coverage
    # @return [Dataset]
    def load(path, root:, format: :auto)
      raw = JSON.parse(File.read(path))
      fmt = (format == :auto) ? detect_format(raw) : format
      abs_entries, source = case fmt
      when :simplecov then from_simplecov(raw, path)
      when :coverage then from_coverage(raw, path)
      else raise Moult::Error, "unknown coverage format: #{fmt}"
      end
      entries, unmatched = relativize(abs_entries, root)
      Dataset.new(entries: entries, source: source, unmatched_count: unmatched)
    rescue JSON::ParserError => e
      raise Moult::Error, "could not parse coverage file #{path}: #{e.message}"
    rescue Errno::ENOENT
      raise Moult::Error, "no such coverage file: #{path}"
    end

    # SimpleCov nests file coverage under a command name and a "coverage" key;
    # stdlib dumps key files at the top level. The presence of "coverage" on the
    # first value is the unambiguous discriminator.
    def detect_format(raw)
      raise Moult::Error, "coverage file is not a JSON object" unless raw.is_a?(Hash)
      sample = raw.values.first
      if sample.is_a?(Hash) && sample.key?("coverage")
        :simplecov
      elsif sample.is_a?(Array) || (sample.is_a?(Hash) && sample.key?("lines"))
        :coverage
      else
        raise Moult::Error, "could not auto-detect coverage format; pass --coverage-format simplecov|coverage"
      end
    end

    # @return [[Hash{String=>Array}, Source]] abs-path line arrays + provenance
    def from_simplecov(raw, _path)
      merged = {}
      timestamps = []
      raw.each_value do |run|
        next unless run.is_a?(Hash)
        timestamps << run["timestamp"] if run["timestamp"]
        (run["coverage"] || {}).each do |file, data|
          merged[file] = merge_lines(merged[file], extract_lines(data))
        end
      end
      collected = timestamps.compact.max
      source = Source.new(
        backend: "simplecov",
        version: nil, # not recorded in the resultset
        collected_at: collected && Time.at(collected).utc.iso8601
      )
      [merged, source]
    end

    # @return [[Hash{String=>Array}, Source]] abs-path line arrays + provenance
    def from_coverage(raw, path)
      entries = {}
      raw.each do |file, data|
        lines = extract_lines(data)
        entries[file] = lines if lines
      end
      # The raw dump carries no timestamp, so the file mtime is the best-effort
      # collected_at (noted as a fallback; only matters for deferred staleness).
      source = Source.new(
        backend: "coverage",
        version: RUBY_VERSION,
        collected_at: File.mtime(path).utc.iso8601
      )
      [entries, source]
    end

    # Accepts both the wrapped ({"lines" => [...]}) and legacy bare-array forms;
    # ignores sibling :methods/:branches data.
    def extract_lines(data)
      case data
      when Array then data
      when Hash then data["lines"]
      end
    end

    # Element-wise merge of two coverage runs: a value is hit if hit in either
    # run (max of the non-nil values), non-executable only if nil in both.
    def merge_lines(a, b)
      return b if a.nil?
      return a if b.nil?
      Array.new([a.length, b.length].max) do |i|
        x, y = a[i], b[i]
        if x.nil? then y
        elsif y.nil? then x
        else [x, y].max
        end
      end
    end

    # Map absolute coverage paths to the root-relative paths Phase 2 emits, so
    # the join lands on the same symbol_id components. Files outside the root are
    # dropped and counted (a different checkout layout, vendored code, etc.).
    def relativize(abs_entries, root)
      real_root = canonicalize(root)
      entries = {}
      unmatched = 0
      abs_entries.each do |abs, lines|
        full = canonicalize(abs)
        if full == real_root || full.start_with?(real_root + File::SEPARATOR)
          entries[SymbolId.relative_path(full, real_root)] = lines
        else
          unmatched += 1
        end
      end
      [entries, unmatched]
    end

    # realpath resolves /tmp -> /private/tmp style symlinks so coverage paths
    # line up with rubydex's canonical paths; falls back when the file is absent
    # locally (coverage collected on another machine).
    def canonicalize(p)
      File.realpath(p)
    rescue
      File.expand_path(p)
    end
  end
end

require_relative "coverage/resolver"
