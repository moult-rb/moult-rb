# frozen_string_literal: true

module Moult
  # The serialized result model for `moult duplication` (schema/duplication.schema.json),
  # sibling to {DeadCodeReport} and {CoverageReport}. It owns the JSON envelope and
  # leaves the other protected contracts untouched. Each {Finding} is a confidence-
  # graded clone group carrying its {Reason}s and {Occurrence}s; nothing here asserts
  # that duplication is certainly removable.
  class DuplicationReport
    # Bump only on a breaking change to the serialized shape.
    SCHEMA_VERSION = 1

    # One site of a clone group. +symbol_id+ is the best-effort enclosing method
    # (the shared cross-analysis join key), nil when the fragment is not inside a
    # known method (top-level code, or a duplicated whole class). +line+ is flay's
    # reported start line — line granularity is all flay provides.
    Occurrence = Struct.new(:symbol_id, :path, :line, :fuzzy) do
      def to_h
        {symbol_id: symbol_id, path: path, line: line, fuzzy: fuzzy}
      end
    end

    # A confidence-graded clone group. Carries its reasons so no claim is made
    # without a recorded justification. +clone_group+ ("<kind>:<structural-hash>")
    # is the group's join key, shared by every occurrence; stable within a report
    # only (the hash comes from the detector backend).
    Finding = Struct.new(:confidence, :kind, :node_type, :mass, :clone_group, :reasons, :occurrences) do
      def to_h
        {
          category: Duplication::Confidence::CATEGORY,
          confidence: confidence,
          kind: kind.to_s,
          node_type: node_type,
          mass: mass,
          clone_group: clone_group,
          reasons: reasons.map(&:to_h),
          occurrences: occurrences.map(&:to_h)
        }
      end
    end

    attr_reader :root, :findings, :git_ref, :generated_at,
      :backend, :backend_version, :min_mass, :fuzzy

    # @param root [String] absolute analysis root
    # @param findings [Array<Finding>] ranked, highest-confidence first
    # @param backend [String] detector backend name (e.g. "flay")
    # @param backend_version [String, nil] backend gem version
    # @param min_mass [Integer] the mass threshold used
    # @param fuzzy [Boolean] whether near-matches were included
    def initialize(root:, findings:, git_ref: nil, generated_at: nil,
      backend: "flay", backend_version: nil, min_mass: nil, fuzzy: false)
      @root = root
      @findings = findings
      @git_ref = git_ref
      @generated_at = generated_at
      @backend = backend
      @backend_version = backend_version
      @min_mass = min_mass
      @fuzzy = fuzzy
    end

    # @return [Hash] aggregate counts across all clone groups
    def summary
      {
        sets: findings.size,
        occurrences: findings.sum { |f| f.occurrences.size },
        total_mass: findings.sum(&:mass)
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
            min_mass: min_mass,
            fuzzy: fuzzy
          }
        },
        summary: summary,
        findings: findings.map(&:to_h)
      }
    end
  end
end
