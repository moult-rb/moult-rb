# frozen_string_literal: true

module Moult
  # The serialized result model for `moult coverage` (schema/coverage.schema.json):
  # a per-symbol hot/cold/untracked map. It is a diagnostic view over the same
  # runtime evidence `moult deadcode --coverage` folds into confidence — it makes
  # no dead-code claim, it only reports what ran.
  #
  # {build} is the orchestration: ask the {Index} for every definition and
  # classify each through {Coverage::Resolver}, joined on the same path + span
  # that make up its symbol_id.
  class CoverageReport
    SCHEMA_VERSION = 1

    # One classified definition. Carries the symbol_id so the map joins to the
    # hotspots and deadcode contracts.
    Entry = Struct.new(:symbol_id, :kind, :name, :span, :runtime) do
      def to_h
        {symbol_id: symbol_id, kind: kind.to_s, name: name, span: span.to_h, runtime: runtime.to_s}
      end
    end

    attr_reader :root, :entries, :git_ref, :generated_at,
      :backend, :backend_version, :resolved, :diagnostics, :coverage_source

    # @param index [Index] resolved definition index
    # @param coverage [Coverage::Dataset] the runtime dataset to resolve against
    # @return [CoverageReport]
    def self.build(index:, coverage:, root:, git_ref: nil, generated_at: nil, backend_version: nil)
      entries = index.definitions.map do |d|
        Entry.new(
          symbol_id: d.symbol_id,
          kind: d.kind,
          name: d.name,
          span: d.span,
          runtime: Coverage::Resolver.classify(coverage, path: d.path, span: d.span, kind: d.kind)
        )
      end
      # Hot first (most surprising/actionable), then cold, then untracked; name
      # as a deterministic tie-break.
      order = {hot: 0, cold: 1, untracked: 2}
      entries.sort_by! { |e| [order.fetch(e.runtime, 3), e.name.to_s] }

      new(
        root: root,
        entries: entries,
        git_ref: git_ref,
        generated_at: generated_at,
        backend: "rubydex",
        backend_version: backend_version,
        resolved: index.resolved?,
        diagnostics: index.diagnostics,
        coverage_source: coverage.source
      )
    end

    def initialize(root:, entries:, git_ref: nil, generated_at: nil,
      backend: "rubydex", backend_version: nil, resolved: true, diagnostics: [], coverage_source: nil)
      @root = root
      @entries = entries
      @git_ref = git_ref
      @generated_at = generated_at
      @backend = backend
      @backend_version = backend_version
      @resolved = resolved
      @diagnostics = diagnostics
      @coverage_source = coverage_source
    end

    # @return [Hash{Symbol=>Integer}] counts keyed :hot, :cold, :untracked
    def summary
      counts = {hot: 0, cold: 0, untracked: 0}
      entries.each { |e| counts[e.runtime] = counts.fetch(e.runtime, 0) + 1 }
      counts
    end

    def to_h
      {
        schema_version: SCHEMA_VERSION,
        tool: {name: "moult", version: Moult::VERSION},
        analysis: {
          root: root,
          git_ref: git_ref,
          generated_at: generated_at,
          coverage: coverage_source&.to_h,
          index: {
            backend: backend,
            backend_version: backend_version,
            resolved: resolved,
            diagnostics: diagnostics
          }
        },
        summary: summary,
        symbols: entries.map(&:to_h)
      }
    end
  end
end
