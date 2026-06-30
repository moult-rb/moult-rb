# frozen_string_literal: true

module Moult
  # Orchestrates the dead-code analysis: it asks the {Index} for every definition,
  # keeps the ones with no production reference, gathers the facts each finding is
  # judged on, and runs them through the pure {Confidence} model. The result is a
  # ranked {DeadCodeReport} of confidence-graded candidates — never assertions of
  # certain death.
  #
  # This is the only layer that knows how the facts are sourced (the index, the
  # Rails conventions, a metaprogramming scan of the owning file); {Confidence}
  # stays a pure function of those facts so it can be tested in isolation.
  module DeadCode
    TEST_PATH = %r{(\A|/)(test|spec)/}

    # Tokens that indicate dynamic dispatch / metaprogramming in a file. Their
    # mere presence lowers confidence for definitions in that file: such code can
    # be reached in ways static analysis cannot see. Matched conservatively (a
    # false match only lowers confidence, never hides a finding).
    DYNAMIC_TOKENS = /
      \b(
        send | public_send | __send__ |
        method_missing | respond_to_missing\? |
        define_method | define_singleton_method |
        class_eval | module_eval | instance_eval | instance_exec |
        const_get | const_set | constantize |
        eval
      )\b
    /x

    module_function

    # @param root [String] absolute analysis root
    # @param files [Array<String>] absolute Ruby file paths analysed
    # @param index [Index] resolved definition/reference index
    # @param rails [RailsConventions] Rails entrypoint awareness
    # @param min_confidence [Float] drop findings below this confidence
    # @param coverage [Coverage::Dataset, nil] runtime coverage to merge (Phase 3)
    # @return [DeadCodeReport]
    def build_report(root:, files:, index:, rails:, min_confidence: 0.0,
      git_ref: nil, generated_at: nil, backend_version: nil, coverage: nil)
      dynamic_files = dynamic_dispatch_files(files, root)

      findings = index.definitions.filter_map do |definition|
        next unless candidate?(definition)
        Confidence.score(context_for(definition, index: index, rails: rails, dynamic_files: dynamic_files, coverage: coverage))
      end

      findings.select! { |f| f.confidence >= min_confidence }
      findings.sort_by! { |f| [-f.confidence, f.name.to_s] }

      DeadCodeReport.new(
        root: root,
        findings: findings,
        git_ref: git_ref,
        generated_at: generated_at,
        backend: "rubydex",
        backend_version: backend_version,
        resolved: index.resolved?,
        rails: rails.rails?,
        diagnostics: index.diagnostics,
        coverage_source: coverage&.source
      )
    end

    # A definition is a candidate when nothing outside of tests references it.
    def candidate?(definition)
      non_test_reference_paths(definition).empty?
    end

    def context_for(definition, index:, rails:, dynamic_files:, coverage: nil)
      Confidence::Context.new(
        symbol_id: definition.symbol_id,
        kind: definition.kind,
        name: definition.name,
        span: definition.span,
        path: definition.path,
        visibility: definition.visibility,
        reference_count: definition.reference_count,
        test_only: test_only?(definition),
        rails_signals: rails.signals_for(definition),
        dynamic_dispatch: dynamic_files.include?(definition.path),
        override_of: definition.override_of,
        deprecated: false,
        index_resolved: index.resolved?,
        runtime: runtime_for(definition, coverage)
      )
    end

    # The runtime classification for this definition, joined on the same path +
    # span that make up its symbol_id. nil when no coverage was supplied.
    def runtime_for(definition, coverage)
      return nil unless coverage
      Coverage::Resolver.classify(
        coverage, path: definition.path, span: definition.span, kind: definition.kind
      )
    end

    # Referenced only from test/spec files: it is exercised, but possibly only to
    # keep otherwise-dead production code alive — a weaker candidate, not excluded.
    def test_only?(definition)
      definition.reference_count.to_i.positive? && non_test_reference_paths(definition).empty?
    end

    def non_test_reference_paths(definition)
      Array(definition.reference_paths).reject { |path| path.to_s.match?(TEST_PATH) }
    end

    # @return [Set<String>] root-relative paths whose source contains dynamic dispatch
    def dynamic_dispatch_files(files, root)
      files.each_with_object(Set.new) do |abs, set|
        source = File.read(abs)
        set << SymbolId.relative_path(abs, root) if source.match?(DYNAMIC_TOKENS)
      rescue
        next
      end
    end
  end
end
