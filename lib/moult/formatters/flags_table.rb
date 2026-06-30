# frozen_string_literal: true

module Moult
  module Formatters
    # Human-readable table of OpenFeature flag references. Renders from the same
    # {FlagsReport} as the JSON formatter so the two cannot disagree. Sorting already
    # happened in {Flags}; this layer owns column formatting only.
    #
    # The heading is deliberate. Without a provider snapshot these are flag *usage*
    # facts (staleness needs a provider). With one, they are confidence-graded
    # staleness *candidates* — never certainties; the STATUS/CONF columns and the
    # heading say so.
    module FlagsTable
      MAX_LOCATIONS = 3
      NO_DEFAULTS = "-"
      NO_STALENESS = "-"
      RIGHT_ALIGNED = [2].freeze # REFS (usage view)
      RIGHT_ALIGNED_GRADED = [3, 4].freeze # CONF, REFS (staleness view)

      module_function

      # @param report [FlagsReport]
      # @return [String]
      def render(report)
        findings = report.findings
        return "No OpenFeature flag references found." if findings.empty?

        graded = !report.provider_source.nil?
        headers = graded ? %w[KEY TYPE STATUS CONF REFS DEFAULTS LOCATIONS] : %w[KEY TYPE REFS DEFAULTS LOCATIONS]
        right = graded ? RIGHT_ALIGNED_GRADED : RIGHT_ALIGNED
        rows = findings.map { |f| row(f, graded) }
        [heading(report.summary, graded), "", TextTable.render(headers, rows, right_aligned: right)].join("\n")
      end

      def heading(summary, graded)
        dynamic = summary[:dynamic_references]
        tail = dynamic.positive? ? ", #{dynamic} dynamic (uncatalogued)" : ""
        lead = if graded
          "OpenFeature flag staleness candidates (confidence-graded, never certain): "
        else
          "OpenFeature flag references (usage facts, not staleness — that needs a live provider): "
        end
        "#{lead}#{summary[:flags]} flags, #{summary[:references]} references#{tail}"
      end

      def row(finding, graded)
        cells = [finding.flag_key, finding.value_type]
        cells.push(status(finding), confidence(finding)) if graded
        cells.push(
          finding.reference_count.to_s,
          defaults(finding.default_values),
          locations(finding.occurrences)
        )
        cells
      end

      def status(finding)
        finding.staleness&.status || NO_STALENESS
      end

      def confidence(finding)
        finding.staleness ? format("%.2f", finding.staleness.confidence) : NO_STALENESS
      end

      def defaults(values)
        values.empty? ? NO_DEFAULTS : values.join(", ")
      end

      def locations(occurrences)
        shown = occurrences.first(MAX_LOCATIONS).map { |o| "#{o.path}:#{o.line}" }
        extra = occurrences.size - shown.size
        extra.positive? ? "#{shown.join(", ")} (+#{extra} more)" : shown.join(", ")
      end
    end
  end
end
