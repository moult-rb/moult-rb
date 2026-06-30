# frozen_string_literal: true

module Moult
  # The serialized result model for `moult health` (schema/health.schema.json),
  # sibling to {DuplicationReport}, {DeadCodeReport} and {CoverageReport}. It owns
  # its own JSON envelope and leaves the other protected contracts untouched.
  #
  # The composite is a confidence-graded health SIGNAL, never a verdict: it records
  # every contributing component (and every skipped/errored one) plus the reasons
  # behind each sub-score, so the headline number is auditable. Nothing here asserts
  # a pass/fail — that gate is Phase 4.
  class HealthReport
    # Bump only on a breaking change to the serialized shape.
    SCHEMA_VERSION = 1

    # One component of the composite, as serialized. +present+ false means the
    # analysis was skipped (e.g. no --coverage) or errored; then +score+ and
    # +normalized_weight+ are null and +diagnostic+ says why.
    ComponentView = Struct.new(:name, :category, :present, :score, :weight,
      :normalized_weight, :summary, :reasons, :diagnostic) do
      def to_h
        {
          name: name,
          category: category,
          present: present,
          score: score,
          weight: weight,
          normalized_weight: normalized_weight,
          summary: summary,
          reasons: reasons.map(&:to_h),
          diagnostic: diagnostic
        }
      end
    end

    # One file's rolled-up health and the join keys that contributed to it.
    # +components+ is a compact name => sub-score map (present components only).
    FileView = Struct.new(:path, :score, :grade, :components, :symbol_ids, :symbol_count) do
      def to_h
        {
          path: path,
          score: score,
          grade: grade,
          components: components,
          symbol_ids: symbol_ids,
          symbol_count: symbol_count
        }
      end
    end

    attr_reader :root, :score, :grade, :components, :files, :git_ref, :generated_at,
      :coverage_source, :churn_window, :churn_since

    # @param root [String] absolute analysis root
    # @param score [Float, nil] composite health in [0, 1]; nil when no component ran
    # @param grade [String, nil] letter grade, or nil
    # @param components [Array<ComponentView>] one per considered analysis, fixed order
    # @param files [Array<FileView>] per-file roll-up, least-healthy first
    # @param coverage_source [Coverage::Source, nil] provenance when coverage was merged
    def initialize(root:, score:, grade:, components:, files:, git_ref: nil, generated_at: nil,
      coverage_source: nil, churn_window: nil, churn_since: nil)
      @root = root
      @score = score
      @grade = grade
      @components = components
      @files = files
      @git_ref = git_ref
      @generated_at = generated_at
      @coverage_source = coverage_source
      @churn_window = churn_window
      @churn_since = churn_since
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
          churn: {window: churn_window, since: churn_since}
        },
        overall: {
          score: score,
          grade: grade,
          components_present: components.count(&:present),
          components_total: components.size,
          files_total: files.size
        },
        components: components.map(&:to_h),
        files: files.map(&:to_h)
      }
    end
  end
end
