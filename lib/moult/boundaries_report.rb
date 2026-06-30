# frozen_string_literal: true

module Moult
  # The serialized result model for `moult boundaries` (schema/boundaries.schema.json),
  # sibling to {DuplicationReport}, {DeadCodeReport}, {CoverageReport} and {HealthReport}.
  # It owns its own JSON envelope and leaves the other protected contracts untouched.
  #
  # Each {Finding} is one recorded architecture-boundary violation group. Unlike the
  # dead-code/duplication contracts it carries +confidence: null+ (a packwerk violation
  # is a recorded fact, not a probabilistic candidate) and a {Boundaries::Severity}
  # classification instead — the honest per-finding grade for this slice. Nothing here
  # asserts the code is *wrong*, only that packwerk recorded a declared-boundary crossing.
  class BoundariesReport
    # Bump only on a breaking change to the serialized shape.
    SCHEMA_VERSION = 1

    # One referencing site of a violation group. +path+ (root-relative) is the join
    # key into the health files[] roll-up. +symbol_id+ is the shared method-level
    # join key, but it is NULL in this slice: packwerk's recorded violations are
    # file-keyed (no line numbers), so there is no line to resolve an enclosing
    # method. It is kept (nullable) for contract consistency with the duplication
    # occurrence shape and to stay forward-compatible with line-level offenses.
    Occurrence = Struct.new(:symbol_id, :path) do
      def to_h
        {symbol_id: symbol_id, path: path}
      end
    end

    # One recorded boundary-violation group: a (referencing_package, defining_package,
    # constant, violation_type) tuple referenced from one or more files. Carries its
    # severity and reasons so the classification is auditable.
    Finding = Struct.new(:violation_type, :severity, :referencing_package, :defining_package,
      :constant, :reasons, :occurrences) do
      def to_h
        {
          category: Boundaries::Severity::CATEGORY,
          confidence: nil,
          violation_type: violation_type,
          severity: severity,
          referencing_package: referencing_package,
          defining_package: defining_package,
          constant: constant,
          reasons: reasons.map(&:to_h),
          occurrences: occurrences.map(&:to_h)
        }
      end
    end

    attr_reader :root, :findings, :git_ref, :generated_at, :backend, :backend_version, :configured

    # @param root [String] absolute analysis root
    # @param findings [Array<Finding>] ranked, most-severe first
    # @param backend [String] detector backend name (e.g. "packwerk")
    # @param backend_version [String, nil] backend gem version, when known
    # @param configured [Boolean] whether the project is packwerk-configured
    def initialize(root:, findings:, git_ref: nil, generated_at: nil,
      backend: "packwerk", backend_version: nil, configured: false)
      @root = root
      @findings = findings
      @git_ref = git_ref
      @generated_at = generated_at
      @backend = backend
      @backend_version = backend_version
      @configured = configured
    end

    # @return [Hash] aggregate counts across all violation groups
    def summary
      {
        findings: findings.size,
        violations: findings.sum { |f| f.occurrences.size },
        by_type: tally { |f| f.violation_type },
        by_severity: tally { |f| f.severity }
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
          detector: {
            backend: backend,
            backend_version: backend_version,
            configured: configured
          }
        },
        summary: summary,
        findings: findings.map(&:to_h)
      }
    end

    private

    # Count findings grouped by the yielded key, occurrence-weighted so the totals
    # match the +violations+ count (one violation = one referencing file).
    def tally
      findings.each_with_object(Hash.new(0)) do |finding, acc|
        acc[yield(finding)] += finding.occurrences.size
      end
    end
  end
end
