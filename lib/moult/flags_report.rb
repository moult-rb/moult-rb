# frozen_string_literal: true

module Moult
  # The serialized result model for `moult flags` (schema/flags.schema.json),
  # sibling to {DuplicationReport}, {DeadCodeReport}, {CoverageReport},
  # {HealthReport} and {BoundariesReport}. It owns its own JSON envelope and leaves
  # the other protected contracts untouched.
  #
  # Each {Finding} is one flag key and the call sites referencing it. Without a
  # provider snapshot it carries +confidence: null+ (a flag reference is a recorded
  # fact) and a {Flags::Classification} signal — the value_type, reference count, and
  # observed default value(s) — and serializes at schema_version 1.
  #
  # When a provider snapshot is merged (the static<->provider merge) each finding
  # ALSO carries a confidence-graded {Flags::Staleness} candidate (status +
  # confidence + reasons), the report carries an analysis.provider provenance block,
  # and the summary a by_staleness_status tally; the envelope reports schema_version
  # 2. The bump is purely additive: with no snapshot the v2-only blocks are omitted
  # and the output is byte-for-byte identical to v1. The snapshot is evidence, never
  # proof — nothing here asserts a flag is certainly stale or dead.
  class FlagsReport
    # The serialized shape's two additive versions. v1 = usage only; v2 = usage +
    # joined staleness candidates (--provider). Bump either only on a breaking change.
    SCHEMA_VERSION = 1
    SCHEMA_VERSION_WITH_PROVIDER = 2

    # One reference site of a flag. +symbol_id+ is the best-effort enclosing-method
    # join key (shared across contracts), nil for a top-level reference. +line+ is
    # the call-site line; +method+ is the OpenFeature fetch method used (it implies
    # the value type and whether the _details variant was called).
    Occurrence = Struct.new(:symbol_id, :path, :line, :method_name) do
      def to_h
        {symbol_id: symbol_id, path: path, line: line, method: method_name}
      end
    end

    # One flag key. Carries its classification (value_type / reference_count /
    # default_values) and reasons so the catalogue is auditable. +staleness+ is a
    # {Flags::Staleness::Assessment} when a provider snapshot was merged, else nil.
    # +confidence+ is the staleness candidate's confidence when graded, else null (a
    # reference alone is a fact, the signal is the classification).
    Finding = Struct.new(:flag_key, :value_type, :reference_count, :default_values, :reasons, :occurrences, :staleness) do
      def to_h
        h = {
          category: Flags::Classification::CATEGORY,
          confidence: staleness&.confidence,
          flag_key: flag_key,
          value_type: value_type,
          reference_count: reference_count,
          default_values: default_values,
          reasons: reasons.map(&:to_h),
          occurrences: occurrences.map(&:to_h)
        }
        # Additive: the staleness block appears only when graded, leaving the v1
        # finding byte-for-byte unchanged (confidence stays null, no extra key).
        h[:staleness] = staleness.to_h if staleness
        h
      end
    end

    attr_reader :root, :findings, :dynamic_references, :git_ref, :generated_at, :provider_source

    # @param root [String] absolute analysis root
    # @param findings [Array<Finding>] ranked, strongest staleness candidate (or
    #   most-referenced, without a snapshot) first
    # @param dynamic_references [Integer] flag-evaluation calls whose key was not a
    #   literal (counted, not catalogued — a static scan cannot resolve the key)
    # @param provider_source [Flags::Snapshot::Source, nil] provenance of a merged
    #   provider snapshot; its presence selects schema_version 2 and the v2-only blocks
    def initialize(root:, findings:, dynamic_references: 0, git_ref: nil, generated_at: nil, provider_source: nil)
      @root = root
      @findings = findings
      @dynamic_references = dynamic_references
      @git_ref = git_ref
      @generated_at = generated_at
      @provider_source = provider_source
    end

    # @return [Hash] aggregate counts across all flags
    def summary
      base = {
        flags: findings.size,
        references: findings.sum { |f| f.occurrences.size },
        dynamic_references: dynamic_references,
        by_value_type: tally { |f| f.value_type }
      }
      # v2-only: the staleness-status tally appears only when a snapshot was merged.
      base[:by_staleness_status] = staleness_tally if provider_source
      base
    end

    def to_h
      {
        schema_version: provider_source ? SCHEMA_VERSION_WITH_PROVIDER : SCHEMA_VERSION,
        tool: {name: "moult", version: Moult::VERSION},
        analysis: analysis,
        summary: summary,
        findings: findings.map(&:to_h)
      }
    end

    private

    # Built incrementally so the provider provenance is appended only when present,
    # leaving the v1 analysis block byte-for-byte unchanged.
    def analysis
      block = {
        root: root,
        git_ref: git_ref,
        generated_at: generated_at,
        scanner: {
          target: FlagScanner::TARGET,
          sdk_gem: FlagScanner::SDK_GEM,
          client_builder: FlagScanner::CLIENT_BUILDER
        }
      }
      block[:provider] = provider_source.to_h if provider_source
      block
    end

    # Flag count keyed by staleness status (one per flag, not reference-weighted).
    def staleness_tally
      findings.each_with_object(Hash.new(0)) do |finding, acc|
        acc[finding.staleness.status] += 1 if finding.staleness
      end
    end

    # Count flags grouped by the yielded key, reference-weighted so the totals match
    # the +references+ count.
    def tally
      findings.each_with_object(Hash.new(0)) do |finding, acc|
        acc[yield(finding)] += finding.occurrences.size
      end
    end
  end
end
