# frozen_string_literal: true

module Moult
  # Orchestrates the duplication analysis: it asks the {Clones} adapter (flay) for
  # every structural clone group, attributes each occurrence to its enclosing
  # method (best-effort, for the cross-analysis join), and grades each group
  # through the pure {Duplication::Confidence} model. The result is a ranked
  # {DuplicationReport} of confidence-graded clone groups — never an assertion
  # that duplication is certainly removable.
  #
  # This is the only layer that knows where the facts come from; {Confidence}
  # stays a pure function of the extracted signals so it can be pinned in
  # isolation.
  module Duplication
    module_function

    # @param root [String] absolute analysis root
    # @param files [Array<String>] absolute Ruby file paths to scan
    # @param min_mass [Integer] flay mass threshold; smaller fragments are ignored
    # @param fuzzy [Boolean] include near-matches (off by default)
    # @param min_confidence [Float] drop findings below this confidence
    # @return [DuplicationReport]
    def build_report(root:, files:, min_mass: Clones::DEFAULT_MIN_MASS, fuzzy: false,
      min_confidence: 0.0, git_ref: nil, generated_at: nil)
      clones = Clones.detect(root: root, files: files, min_mass: min_mass, fuzzy: fuzzy)
      methods = MethodIndex.new(root: root, files: files)

      findings = clones.sets.map { |set| finding_for(set, methods) }
      findings.select! { |f| f.confidence >= min_confidence }
      # Highest-confidence first, then heaviest, with node type as a deterministic
      # tie-break so output is stable across runs.
      findings.sort_by! { |f| [-f.confidence, -f.mass, f.node_type] }

      DuplicationReport.new(
        root: root,
        findings: findings,
        git_ref: git_ref,
        generated_at: generated_at,
        backend: clones.backend,
        backend_version: clones.backend_version,
        min_mass: clones.min_mass,
        fuzzy: clones.fuzzy
      )
    end

    def finding_for(set, methods)
      assessment = Confidence.assess(
        kind: set.kind,
        mass: set.mass,
        occurrence_count: set.occurrences.size,
        node_type: set.node_type
      )
      occurrences = set.occurrences.map do |occ|
        DuplicationReport::Occurrence.new(
          symbol_id: methods.symbol_id_at(occ.path, occ.line),
          path: occ.path,
          line: occ.line,
          fuzzy: occ.fuzzy
        )
      end
      DuplicationReport::Finding.new(
        confidence: assessment.confidence,
        kind: set.kind,
        node_type: set.node_type,
        mass: set.mass,
        clone_group: "#{set.kind}:#{set.structural_hash}",
        reasons: assessment.reasons,
        occurrences: occurrences
      )
    end

    # Best-effort line -> enclosing-method resolution, reusing the Prism {Parser}
    # so the minted ids are byte-identical to the hotspots/deadcode join keys.
    # flay reports a clone's start line only; we attribute it to the innermost
    # method whose span contains that line. Files are parsed lazily and memoised;
    # a fragment outside any method (top-level code, a whole class) resolves to nil.
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

require_relative "duplication/confidence"
