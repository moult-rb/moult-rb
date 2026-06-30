# frozen_string_literal: true

module Moult
  # CI projections of the gate verdict. These render the SAME contributing
  # findings the JSON contract carries into machine formats a code-review tool can
  # consume — but they only EMIT text (annotations / a SARIF document). Posting to
  # any GitHub API is the App's job (Phase 4), explicitly out of scope here.
  module Formatters
    # GitHub Actions workflow-command annotations: one `::error` line per
    # contributing finding, so a PR shows the gate's findings inline when run in
    # Actions. Format and escaping follow the GitHub Actions workflow-commands
    # spec. A passing gate emits a single `::notice`.
    module GateGithub
      module_function

      # @param report [GateReport]
      # @return [String]
      def render(report)
        failed = report.rules.select { |r| r.evaluated && r.passed == false }
        return pass_notice(report) if failed.empty?

        failed.flat_map { |rule| rule.findings.map { |f| annotation(rule, f) } }.join("\n")
      end

      def pass_notice(report)
        "::notice title=#{escape_prop("Moult gate")}::#{escape_data("gate passed (#{report.summary[:evaluated]} rules evaluated)")}"
      end

      def annotation(rule, finding)
        props = {file: finding.path}
        props[:line] = finding.line if finding.line
        props[:title] = "Moult gate: #{rule.rule}"
        prop_str = props.map { |k, v| "#{k}=#{escape_prop(v.to_s)}" }.join(",")
        "::error #{prop_str}::#{escape_data(message(rule, finding))}"
      end

      def message(rule, finding)
        GateMessage.for(rule, finding)
      end

      # Per the workflow-command spec: escape % CR LF in message data; additionally
      # escape : and , in property values.
      def escape_data(value)
        value.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
      end

      def escape_prop(value)
        escape_data(value).gsub(":", "%3A").gsub(",", "%2C")
      end
    end
  end
end
