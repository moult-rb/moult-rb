# frozen_string_literal: true

module Moult
  # Orchestrates the architecture-boundaries analysis: it asks the {Boundaries::Packwerk}
  # adapter for every recorded violation, groups them into findings, and grades each
  # group through the pure {Boundaries::Severity} model. The result is a ranked
  # {BoundariesReport} of confidence-null, severity-classified boundary violations —
  # recorded facts, never claims that the code is wrong.
  #
  # This is the only layer that knows where the facts come from; {Severity} stays a
  # pure function of the violation type so it can be pinned in isolation.
  module Boundaries
    module_function

    # A finding is one group of violations sharing this identity (the same constant
    # crossing the same package boundary in the same way); its occurrences are the
    # referencing files.
    GROUP_KEY = %i[referencing_package defining_package constant violation_type].freeze

    # @param root [String] absolute analysis root
    # @param min_severity [String, nil] drop findings below this severity (low<medium<high)
    # @return [BoundariesReport]
    def build_report(root:, min_severity: nil, git_ref: nil, generated_at: nil)
      result = Packwerk.detect(root: root)

      findings = group(result.violations).map { |key, violations| finding_for(key, violations) }
      findings.select! { |f| meets?(f.severity, min_severity) } if min_severity
      findings.sort_by! { |f| sort_key(f) }

      BoundariesReport.new(
        root: root,
        findings: findings,
        git_ref: git_ref,
        generated_at: generated_at,
        backend: result.backend,
        backend_version: result.backend_version,
        configured: result.configured
      )
    end

    def group(violations)
      violations.group_by { |v| GROUP_KEY.map { |k| v[k] } }
    end

    def finding_for(key, violations)
      referencing_package, defining_package, constant, violation_type = key
      assessment = Severity.classify(violation_type: violation_type)
      occurrences = violations
        .map(&:path).uniq.sort
        .map { |path| BoundariesReport::Occurrence.new(symbol_id: nil, path: path) }
      BoundariesReport::Finding.new(
        violation_type: violation_type,
        severity: assessment.severity,
        referencing_package: referencing_package,
        defining_package: defining_package,
        constant: constant,
        reasons: assessment.reasons,
        occurrences: occurrences
      )
    end

    # Most-severe first, then a deterministic alphabetical tie-break so output is
    # stable across runs.
    def sort_key(finding)
      [-Severity::SCALE.index(finding.severity), finding.violation_type,
        finding.referencing_package, finding.defining_package, finding.constant]
    end

    def meets?(severity, floor)
      Severity::SCALE.index(severity) >= Severity::SCALE.index(floor.to_s)
    end
  end
end

require_relative "boundaries/packwerk"
require_relative "boundaries/severity"
require_relative "boundaries_report"
