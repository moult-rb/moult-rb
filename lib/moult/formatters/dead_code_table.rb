# frozen_string_literal: true

module Moult
  module Formatters
    # Human-readable table of dead-code candidates. Renders from the same
    # {DeadCodeReport} as the JSON formatter so the two cannot disagree. Sorting
    # already happened in {DeadCode}; this layer owns column formatting only.
    #
    # The heading is deliberate: these are confidence-graded candidates, never
    # certainties.
    module DeadCodeTable
      # Only the CONF column (col 0) is right-aligned.
      RIGHT_ALIGNED = [0].freeze

      module_function

      # @param report [DeadCodeReport]
      # @return [String]
      def render(report)
        findings = report.findings
        return "No dead-code candidates found." if findings.empty?

        # The RUNTIME column only appears when coverage was merged, so output
        # without --coverage is byte-for-byte unchanged from Phase 2.
        runtime = findings.any? { |f| !f.runtime.nil? }
        headers = columns(runtime)
        rows = findings.map { |f| row(f, runtime) }
        [heading(findings.size), "", TextTable.render(headers, rows, right_aligned: RIGHT_ALIGNED)].join("\n")
      end

      def columns(runtime)
        cols = ["CONF", "KIND"]
        cols << "RUNTIME" if runtime
        cols + ["SYMBOL", "LOCATION", "TOP REASON"]
      end

      def heading(count)
        "Dead-code candidates (confidence-graded — not certainties): #{count} findings"
      end

      def row(finding, runtime)
        cells = [conf(finding.confidence), finding.kind.to_s]
        cells << (finding.runtime&.to_s || "-") if runtime
        cells + [finding.name.to_s, location(finding), top_reason(finding)]
      end

      def location(finding)
        span = finding.span
        line = span&.start_line
        line ? "#{finding.path}:#{line}" : finding.path.to_s
      end

      # The most informative reason is the last applied non-base adjustment;
      # fall back to the base reason for a bare candidate.
      def top_reason(finding)
        reasons = finding.reasons.reject { |r| r.rule == :base_score }
        chosen = reasons.last || finding.reasons.first
        chosen ? chosen.detail.to_s : "-"
      end

      def conf(value)
        format("%.2f", value)
      end
    end
  end
end
