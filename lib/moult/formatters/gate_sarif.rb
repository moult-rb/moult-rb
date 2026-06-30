# frozen_string_literal: true

require "json"

module Moult
  module Formatters
    # SARIF 2.1.0 projection of the gate verdict — the static-analysis interchange
    # format GitHub code scanning and reviewdog consume. One `rule` per policy
    # rule; one `result` (level "error") per contributing finding behind a failed
    # rule. Emits the document only; uploading it is the consumer's job.
    #
    # A finding's `value` is a graded/classified signal (confidence/ABC/mass/
    # severity), so the result text reports it as such — never as a certainty.
    module GateSarif
      SARIF_SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json"
      INFORMATION_URI = "https://github.com/moult-rb/moult-rb"

      module_function

      # @param report [GateReport]
      # @return [String]
      def render(report)
        JSON.pretty_generate(document(report))
      end

      def document(report)
        {
          "$schema" => SARIF_SCHEMA,
          "version" => "2.1.0",
          "runs" => [{
            "tool" => {
              "driver" => {
                "name" => "moult",
                "version" => Moult::VERSION,
                "informationUri" => INFORMATION_URI,
                "rules" => report.rules.map { |r| rule_descriptor(r) }
              }
            },
            "results" => results(report)
          }]
        }
      end

      def rule_descriptor(rule)
        {
          "id" => rule.rule,
          "shortDescription" => {"text" => rule.rule.tr("_", " ")},
          "properties" => {"threshold" => rule.threshold.to_s, "evaluated" => rule.evaluated}
        }
      end

      def results(report)
        report.rules.select { |r| r.evaluated && r.passed == false }.flat_map do |rule|
          rule.findings.map { |f| result(rule, f) }
        end
      end

      def result(rule, finding)
        {
          "ruleId" => rule.rule,
          "level" => "error",
          "message" => {"text" => message(rule, finding)},
          "locations" => [{"physicalLocation" => physical_location(finding)}]
        }
      end

      def physical_location(finding)
        location = {"artifactLocation" => {"uri" => finding.path}}
        location["region"] = {"startLine" => finding.line} if finding.line
        location
      end

      def message(rule, finding)
        GateMessage.for(rule, finding)
      end
    end
  end
end
