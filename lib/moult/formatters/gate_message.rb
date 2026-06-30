# frozen_string_literal: true

module Moult
  module Formatters
    # The one-line description of a gate finding, shared by the GitHub-annotation
    # and SARIF projections so the two render identical text. Stays humble: it
    # reports the observed signal against the threshold, never a claim of certainty.
    module GateMessage
      module_function

      # @param rule [Gate::Evaluation::RuleOutcome]
      # @param finding [Gate::Evaluation::Contribution]
      # @return [String]
      def for(rule, finding)
        "#{finding.category} #{finding.value} on changed code violates #{rule.rule} (threshold #{rule.threshold})"
      end
    end
  end
end
