# frozen_string_literal: true

module Moult
  # The serialized result model for `moult cycles` (schema/cycles.schema.json),
  # sibling to {DuplicationReport} and {DeadCodeReport}. Each {Finding} is one
  # strongly-connected component of the file dependency graph, carrying the
  # resolved constant-reference edges as its evidence.
  class CyclesReport
    # Bump only on a breaking change to the serialized shape.
    SCHEMA_VERSION = 1

    # One circular file-dependency group. +cycle_group+ ("scc:<hash of the
    # sorted member files>") is the group's join key — membership-stable
    # across runs and machines, unlike a detector-backend hash. +edges+ are
    # the in-cycle dependencies, each with a representative reference site.
    Finding = Struct.new(:cycle_group, :confidence, :category, :size, :files, :reasons, :edges) do
      def to_h
        {
          cycle_group: cycle_group,
          category: category,
          confidence: confidence,
          size: size,
          files: files,
          reasons: reasons.map(&:to_h),
          edges: edges.map { |e| {src: e.src, dst: e.dst, constant: e.constant, span: e.span.to_h} }
        }
      end
    end

    attr_reader :root, :findings, :git_ref, :generated_at,
      :backend, :backend_version, :resolved, :diagnostics

    # @param root [String] absolute analysis root
    # @param findings [Array<Finding>] ranked, largest cycle first
    # @param backend [String] index backend name (e.g. "rubydex")
    # @param backend_version [String, nil] backend gem version
    def initialize(root:, findings:, git_ref: nil, generated_at: nil,
      backend: "rubydex", backend_version: nil, resolved: true, diagnostics: [])
      @root = root
      @findings = findings
      @git_ref = git_ref
      @generated_at = generated_at
      @backend = backend
      @backend_version = backend_version
      @resolved = resolved
      @diagnostics = diagnostics
    end

    # @return [Hash] aggregate counts across all cycles
    def summary
      {
        cycles: findings.size,
        files: findings.sum { |f| f.files.size },
        largest: findings.map(&:size).max || 0
      }
    end

    def to_h
      {
        schema_version: SCHEMA_VERSION,
        tool: {name: "moult", version: Moult::VERSION},
        analysis: {
          root: root,
          git_ref: git_ref,
          generated_at: generated_at,
          index: {
            backend: backend,
            backend_version: backend_version,
            resolved: resolved,
            diagnostics: diagnostics
          }
        },
        summary: summary,
        findings: findings.map(&:to_h)
      }
    end
  end
end
