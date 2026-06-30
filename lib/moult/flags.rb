# frozen_string_literal: true

module Moult
  # Orchestrates the feature-flag analysis: it asks the {FlagScanner} for every
  # OpenFeature flag-evaluation call site, groups them by flag key, attributes each
  # site to its enclosing method (best-effort, for the cross-analysis join), and
  # grades each group through the pure {Flags::Classification} model. The result is
  # a {FlagsReport} cataloguing flag USAGE.
  #
  # When a provider snapshot is supplied (the static<->provider merge, the flags
  # analogue of the static<->runtime coverage merge), it ALSO joins each flag key to
  # the provider's recorded state and grades a confidence-graded {Staleness}
  # candidate — the first real use of the per-finding confidence slot in this slice.
  # The snapshot is evidence, never proof; nothing here asserts a flag is certainly
  # stale or dead.
  #
  # This is the only layer that joins the facts to symbols and to the provider;
  # {Classification} and {Staleness} stay pure functions of the observed signals so
  # they can be pinned in isolation, {FlagScanner} stays the sole keeper of the
  # OpenFeature call shape, and {Snapshot} the sole keeper of the export format.
  module Flags
    module_function

    # @param root [String] absolute analysis root
    # @param files [Array<String>] absolute Ruby file paths to scan
    # @param snapshot [Snapshot::FlagSet, nil] a merged provider snapshot; when given,
    #   each finding gains a confidence-graded staleness candidate joined on flag_key
    # @return [FlagsReport]
    def build_report(root:, files:, git_ref: nil, generated_at: nil, snapshot: nil)
      sites = files.flat_map { |abs| scan(abs, root) }
      methods = MethodIndex.new(root: root, files: files)

      literal, dynamic = sites.partition { |s| !s.flag_key.nil? }
      has_dynamic = dynamic.size.positive?
      findings = literal.group_by(&:flag_key).map { |key, group| finding_for(key, group, methods, snapshot, has_dynamic) }
      # With a snapshot, strongest staleness candidate first (then refs, then key);
      # without, most-referenced first. Either way alphabetical by key breaks ties so
      # output is stable.
      findings.sort_by! do |f|
        f.staleness ? [-f.staleness.confidence, -f.reference_count, f.flag_key] : [-f.reference_count, f.flag_key]
      end

      FlagsReport.new(
        root: root,
        findings: findings,
        dynamic_references: dynamic.size,
        git_ref: git_ref,
        generated_at: generated_at,
        provider_source: snapshot&.source
      )
    end

    def scan(abs, root)
      FlagScanner.scan_file(abs, SymbolId.relative_path(abs, root))
    rescue
      []
    end

    def finding_for(key, sites, methods, snapshot = nil, has_dynamic = false)
      assessment = Classification.classify(
        value_types: sites.map(&:value_type),
        default_values: sites.map(&:default_value)
      )
      occurrences = sites
        .sort_by { |s| [s.path, s.line] }
        .map { |s| FlagsReport::Occurrence.new(symbol_id: methods.symbol_id_at(s.path, s.line), path: s.path, line: s.line, method_name: s.method_name) }
      staleness = staleness_for(key, snapshot, has_dynamic)
      FlagsReport::Finding.new(
        flag_key: key,
        value_type: assessment.value_type,
        reference_count: assessment.reference_count,
        default_values: assessment.default_values,
        reasons: assessment.reasons,
        occurrences: occurrences,
        staleness: staleness
      )
    end

    # The staleness candidate for a key, joined on the literal flag_key (the flags
    # join key, mirroring how coverage joins on symbol_id). nil when no snapshot was
    # supplied, leaving the finding byte-for-byte v1-identical.
    def staleness_for(key, snapshot, has_dynamic)
      return nil unless snapshot
      Staleness.classify(state: snapshot.state_for(key), has_dynamic_references: has_dynamic)
    end

    # Best-effort line -> enclosing-method resolution, reusing the Prism {Parser} so
    # the minted ids are byte-identical to the hotspots/deadcode/duplication join
    # keys. We attribute a call site to the innermost method whose span contains its
    # line; files are parsed lazily and memoised. A reference outside any method
    # (top-level code) resolves to nil. (Mirrors {Duplication::MethodIndex}.)
    class MethodIndex
      def initialize(root:, files:)
        @abs_by_rel = files.to_h { |abs| [SymbolId.relative_path(abs, root), abs] }
        @cache = {}
      end

      # @return [String, nil] symbol_id of the innermost containing method, or nil
      def symbol_id_at(rel_path, line)
        method = enclosing_method(rel_path, line)
        return nil unless method
        SymbolId.for(path: rel_path, start_line: method.span.start_line, fqname: method.name)
      end

      private

      def enclosing_method(rel_path, line)
        methods_for(rel_path)
          .select { |m| line.between?(m.span.start_line, m.span.end_line) }
          .min_by { |m| m.span.end_line - m.span.start_line }
      end

      def methods_for(rel_path)
        @cache[rel_path] ||= parse(rel_path)
      end

      def parse(rel_path)
        abs = @abs_by_rel[rel_path]
        return [] unless abs
        Parser.parse_file(abs)
      rescue
        []
      end
    end
  end
end

require_relative "flags/classification"
require_relative "flags/staleness"
require_relative "flags/snapshot"
require_relative "flags_report"
