# frozen_string_literal: true

module Moult
  module Gate
    # The explicit, recorded set of thresholds the gate enforces — the realisation
    # of "Clean as You Code" for Moult. A Policy is a plain value object; the
    # thresholds it carries are serialized into every gate report so the verdict is
    # auditable (never a hidden heuristic) and reproducible.
    #
    # The {DEFAULTS} are judgement-based heuristics in the spirit of the health
    # knees — calibrated against a real corpus (Moult's own codebase: a default
    # must let a clean, well-tested gem pass). They are pinned in
    # test/test_gate_policy.rb; drift is a bug. Teams override them via the `gate:`
    # section of .moult.yml.
    class Policy
      DEFAULTS = {
        # A dead-code candidate on changed lines at or above this confidence fails
        # the gate. Public symbols base well below this; the rule bites freshly
        # added unused private methods — the canonical "new dead code" smell.
        dead_code_max_confidence: 0.8,

        # The highest boundary severity allowed to appear in a changed file. With
        # "medium", a new HIGH-severity packwerk violation (dependency/layer) fails.
        boundary_max_severity: "medium",

        # A changed method whose ABC complexity exceeds this ceiling fails the gate.
        complexity_ceiling: 30.0,

        # A clone group touching the diff whose flay mass exceeds this fails. Set to
        # roughly a fully duplicated ~10-line method: below it lies idiomatic
        # parallelism (sibling guard clauses, similar small methods) that a clean
        # codebase legitimately has, so a lower bar produces noise, not signal.
        duplication_max_mass: 100,

        # Path prefixes excluded from gating. Test/spec code is legitimately
        # repetitive (parallel cases, shared setup), so — like SonarQube and
        # CodeScene — the gate judges production code. Findings under these prefixes
        # are dropped from every rule. Override to [] to gate everything.
        exclude_paths: ["test", "spec"]
      }.freeze

      KEYS = DEFAULTS.keys.freeze

      attr_reader :dead_code_max_confidence, :boundary_max_severity,
        :complexity_ceiling, :duplication_max_mass, :exclude_paths, :source

      def initialize(dead_code_max_confidence:, boundary_max_severity:,
        complexity_ceiling:, duplication_max_mass:, exclude_paths:, source:)
        @dead_code_max_confidence = dead_code_max_confidence
        @boundary_max_severity = boundary_max_severity
        @complexity_ceiling = complexity_ceiling
        @duplication_max_mass = duplication_max_mass
        @exclude_paths = exclude_paths
        @source = source
      end

      class << self
        # The pinned defaults, recorded with source "default".
        # @return [Policy]
        def default
          load({}, source: "default")
        end

        # Merge a (string- or symbol-keyed) overrides hash onto {DEFAULTS}. Unknown
        # keys are ignored so a stray .moult.yml entry can't silently weaken the gate.
        # @param overrides [Hash]
        # @param source [String] provenance for the report (e.g. ".moult.yml")
        # @return [Policy]
        def load(overrides, source:)
          new(**DEFAULTS.merge(sanitize(overrides)), source: source)
        end

        private

        def sanitize(overrides)
          (overrides || {}).each_with_object({}) do |(key, value), acc|
            sym = key.to_sym
            acc[sym] = value if KEYS.include?(sym)
          end
        end
      end

      # Is +path+ (root-relative) outside the gate's scope — i.e. under an excluded
      # prefix like test/ or spec/?
      def excluded?(path)
        segment = path.to_s.split("/").first
        exclude_paths.include?(segment)
      end

      # The auditable record of every applied threshold.
      def to_h
        {
          source: source,
          dead_code_max_confidence: dead_code_max_confidence,
          boundary_max_severity: boundary_max_severity,
          complexity_ceiling: complexity_ceiling,
          duplication_max_mass: duplication_max_mass,
          exclude_paths: exclude_paths
        }
      end
    end
  end
end
