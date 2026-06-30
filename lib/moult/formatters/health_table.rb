# frozen_string_literal: true

module Moult
  module Formatters
    # Human-readable health summary: a headline composite, the per-component
    # breakdown (including the skipped/errored ones), and the least-healthy files.
    # Renders from the same {HealthReport} as the JSON formatter so the two cannot
    # disagree; ordering already happened in {Health}.
    #
    # The heading is deliberate: this is a graded signal, never a verdict.
    module HealthTable
      DEFAULT_FILE_LIMIT = 20
      DASH = "—"

      module_function

      # @param report [HealthReport]
      # @param file_limit [Integer, nil] how many worst files to show (nil = all)
      # @return [String]
      def render(report, file_limit: DEFAULT_FILE_LIMIT)
        [heading(report), "", components_section(report), "", files_section(report, file_limit)]
          .join("\n").rstrip
      end

      def heading(report)
        if report.score.nil?
          "Codebase health: n/a — no analysis produced a signal"
        else
          present = report.components.count(&:present)
          total = report.components.size
          "Codebase health: #{report.grade} (#{format("%.2f", report.score)}) " \
            "— a graded signal, not a verdict  [#{present}/#{total} components]"
        end
      end

      def components_section(report)
        headers = %w[COMPONENT SCORE WEIGHT NOTE]
        rows = report.components.map { |c| component_row(c) }
        right = [1, 2] # SCORE, WEIGHT
        ["Components:", TextTable.render(headers, rows, right_aligned: right)].join("\n")
      end

      def component_row(component)
        [
          component.name,
          component.present ? format("%.2f", component.score) : DASH,
          format("%.2f", component.weight),
          component_note(component)
        ]
      end

      def component_note(component)
        return component.diagnostic.to_s unless component.present
        component.reasons.first&.detail.to_s
      end

      def files_section(report, file_limit)
        files = report.files
        return "Files: none with a health signal." if files.empty?

        shown = file_limit ? files.first(file_limit) : files
        headers = %w[SCORE GRADE FILE COMPONENTS]
        rows = shown.map { |f| file_row(f) }
        extra = files.size - shown.size
        suffix = extra.positive? ? " (top #{shown.size} of #{files.size})" : ""
        title = "Least-healthy files#{suffix}:"
        [title, TextTable.render(headers, rows, right_aligned: [0])].join("\n")
      end

      def file_row(file)
        [
          format("%.2f", file.score),
          file.grade,
          file.path,
          file.components.keys.join(",")
        ]
      end
    end
  end
end
