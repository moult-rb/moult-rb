# frozen_string_literal: true

module Moult
  module Formatters
    # Human-readable gate result: a PASS/FAIL banner, the scope it ran over, a
    # per-rule table (with each rule's observed value vs threshold), and the
    # contributing findings behind any failure. Renders from the same {GateReport}
    # as the JSON/CI formatters so they cannot disagree.
    #
    # The verdict is an auditable application of the recorded policy — the heading
    # says so; nothing here claims the code is certainly wrong.
    module GateTable
      module_function

      # @param report [GateReport]
      # @return [String]
      def render(report)
        [banner(report), "", rule_table(report), contributions(report)]
          .reject(&:empty?).join("\n")
      end

      def banner(report)
        verdict = report.verdict.upcase
        "moult gate: #{verdict}  (#{scope_label(report)})"
      end

      def scope_label(report)
        if report.scope == :all || report.scope == "all"
          "scope: all (whole codebase)"
        else
          base = report.base_ref || "base"
          mb = report.merge_base ? " @ #{report.merge_base[0, 7]}" : ""
          "scope: diff vs #{base}#{mb}"
        end
      end

      def rule_table(report)
        headers = %w[RULE OBSERVED THRESHOLD RESULT]
        rows = report.rules.map do |rule|
          [rule.rule, observed(rule), rule.threshold.to_s, result(rule)]
        end
        TextTable.render(headers, rows)
      end

      def observed(rule)
        return "-" if rule.observed.nil?

        rule.observed.to_s
      end

      def result(rule)
        return "skipped" unless rule.evaluated

        rule.passed ? "pass" : "FAIL"
      end

      def contributions(report)
        failed = report.rules.select { |r| r.evaluated && r.passed == false }
        return "" if failed.empty?

        lines = failed.flat_map { |rule| rule.findings.map { |f| contribution_line(rule, f) } }
        ["", "Contributing findings:", *lines].join("\n")
      end

      def contribution_line(rule, finding)
        loc = finding.line ? "#{finding.path}:#{finding.line}" : finding.path
        "  [#{rule.rule}] #{loc}  #{finding.category} (#{finding.value})"
      end
    end
  end
end
