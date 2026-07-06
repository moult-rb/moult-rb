# frozen_string_literal: true

require "pathname"

module Moult
  # Aggregates the per-method ABC and per-file churn into a ranked {Report}.
  #
  # File complexity is the sum of its methods' ABC; the file score is
  # complexity x churn. This raw product is dominated by outliers - acceptable
  # for v0.1, but {combine} is isolated so a normalisation strategy (log, rank,
  # z-score) can drop in later without touching the rest of the pipeline.
  #
  # Files with no methods (or only zero-scoring ones) are omitted: they cannot
  # be a complexity hotspot. Ranking is score-descending, with complexity then
  # path as deterministic tie-breakers (so 0-churn files - e.g. outside a repo -
  # still order by complexity rather than arbitrarily).
  module Scoring
    DEFAULT_WORST_METHODS = 3

    module_function

    # @param root [String] absolute analysis root
    # @param files [Array<String>] absolute paths of Ruby files to analyse
    # @param churn [Hash{String=>Integer}] path (relative to root) => commit count
    # @param worst_methods [Integer] how many worst methods to keep per file
    # @param edges [Array<#src,#dst>, nil] unique file dependency pairs (e.g.
    #   {Index#file_edges}); nil leaves the coupling columns null
    # @return [Report]
    def build_report(root:, files:, churn:, worst_methods: DEFAULT_WORST_METHODS,
      git_ref: nil, generated_at: nil, churn_window: nil, churn_since: nil, edges: nil)
      coupling = coupling_degrees(edges)
      hotspots = files.filter_map do |abs|
        hotspot_for(abs, root: root, churn: churn, worst_methods: worst_methods, coupling: coupling)
      end
      hotspots.sort_by! { |h| [-h.score, -h.complexity, h.path] }

      Report.new(
        root: root,
        hotspots: hotspots,
        git_ref: git_ref,
        generated_at: generated_at,
        churn_window: churn_window,
        churn_since: churn_since
      )
    end

    # @return [Report::Hotspot, nil] nil when the file has no scoring methods
    def hotspot_for(abs, root:, churn:, worst_methods:, coupling: nil)
      rel = relative_path(abs, root)
      methods = Parser.parse_file(abs).map { |m| build_method(m, rel) }
      complexity = methods.sum(0.0, &:abc)
      return nil if complexity.zero?

      churn_count = churn[rel]
      kept = methods.sort_by { |m| -m.abc }.first(worst_methods)

      Report::Hotspot.new(
        path: rel,
        score: combine(complexity, churn_count).round(2),
        complexity: complexity.round(2),
        churn: churn_count,
        methods: kept,
        **coupling_fields(rel, coupling)
      )
    end

    # The v0.1 scoring rule. Swap-point for future normalisation. Coupling is
    # deliberately not a factor: weighting by instability would bury complex,
    # churned, high-fan-in files — exactly the hotspots that matter most.
    # @return [Numeric]
    def combine(complexity, churn)
      complexity * churn
    end

    # In/out degree per file over the unique dependency pairs. nil when no
    # edges were supplied (coupling unknown).
    def coupling_degrees(edges)
      return nil unless edges
      {
        out: edges.group_by(&:src).transform_values(&:size),
        in: edges.group_by(&:dst).transform_values(&:size)
      }
    end

    # A file absent from the edge set is measured-as-isolated (0/0), not
    # unknown: the index saw it and found no resolved dependencies.
    def coupling_fields(rel, coupling)
      return {fan_in: nil, fan_out: nil, instability: nil} unless coupling
      fan_in = coupling[:in][rel] || 0
      fan_out = coupling[:out][rel] || 0
      total = fan_in + fan_out
      {
        fan_in: fan_in,
        fan_out: fan_out,
        instability: total.zero? ? 0.0 : (fan_out.to_f / total).round(2)
      }
    end

    def build_method(method_def, rel)
      Report::Method.new(
        symbol_id: SymbolId.for(path: rel, start_line: method_def.span.start_line, fqname: method_def.name),
        name: method_def.name,
        span: method_def.span,
        abc: ABC.score(method_def.node)
      )
    end

    def relative_path(abs, root)
      SymbolId.relative_path(abs, root)
    end
  end
end
