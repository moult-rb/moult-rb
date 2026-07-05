# frozen_string_literal: true

module Moult
  # Orchestrates the diff-aware PR risk gate — the capstone of the static layer and
  # the gem-level core of what later becomes the GitHub App.
  #
  # It reuses {Health}'s composer discipline: each signal analysis runs inside its
  # own rescue so one failure degrades that rule (evaluated: false) rather than
  # crashing the gate. It then scopes every finding to the diff (via {Diff}),
  # extracts pure observations, and hands them to the pinned {Gate::Evaluation}
  # model together with the recorded {Gate::Policy}. This file is the only layer
  # that does IO and knows where the signals come from; Policy/Evaluation stay pure
  # functions so they can be pinned in isolation.
  #
  # The gate consumes signals and renders a verdict; it never mutates a signal
  # contract, and the two protected APIs are untouched. The verdict is an auditable
  # application of an explicit policy over confidence-graded candidates — never a
  # claim that code is certainly wrong or dead.
  module Gate
    # Fixed component order so the provenance block is stable.
    KNOWN_COMPONENTS = %w[complexity dead_code duplication boundaries].freeze

    # The outcome of one isolated analysis run (mirrors {Health::Run}).
    Run = Struct.new(:value, :error) do
      def ok?
        error.nil? && !value.nil?
      end
    end

    module_function

    # @param root [String] absolute analysis root (should be the repo root)
    # @param files [Array<String>] absolute Ruby file paths to analyse
    # @param index [Index] resolved definition/reference index (drives dead code)
    # @param rails [RailsConventions] Rails entrypoint awareness for dead code
    # @param base_ref [String] base ref for the diff (e.g. "origin/main")
    # @param scope [Symbol] :diff (default) or :all
    # @param policy [Gate::Policy] the thresholds to apply
    # @param churn_since [String, nil] churn window for the complexity analysis
    # @return [GateReport]
    def build_report(root:, files:, index:, rails:, base_ref:, scope:, policy:,
      git_ref: nil, generated_at: nil, churn_since: nil)
      diff = Diff.compute(root: root, base_ref: base_ref, scope: scope)
      runs = run_analyses(root: root, files: files, index: index, rails: rails, churn_since: churn_since)
      observations = observe(runs, diff, policy)

      GateReport.new(
        root: root,
        base_ref: diff.base_ref,
        merge_base: diff.merge_base,
        scope: diff.scope,
        components: component_views(runs),
        policy: policy,
        evaluation: Evaluation.evaluate(observations: observations, policy: policy),
        git_ref: git_ref,
        generated_at: generated_at
      )
    end

    # Run each signal analysis in isolation (the composer discipline).
    def run_analyses(root:, files:, index:, rails:, churn_since:)
      # Churn is only collected to satisfy {Scoring}; the complexity rule reads
      # each method's ABC + span, which are churn-independent.
      churn = Churn.collect(root: root, since: churn_since || Churn::DEFAULT_SINCE)
      {
        "complexity" => run { Scoring.build_report(root: root, files: files, churn: churn) },
        "dead_code" => run { DeadCode.build_report(root: root, files: files, index: index, rails: rails) },
        "duplication" => run { Duplication.build_report(root: root, files: files) },
        "boundaries" => run { Boundaries.build_report(root: root) }
      }
    end

    # Scope every analysis's findings to the diff, into pure observations, then drop
    # any under an excluded path (test/spec) so the gate judges production code.
    def observe(runs, diff, policy)
      Evaluation::Observations.new(
        complexity: gated(scope_complexity(runs["complexity"], diff), policy),
        dead_code: gated(scope_dead_code(runs["dead_code"], diff), policy),
        duplication: gated(scope_duplication(runs["duplication"], diff), policy),
        boundaries: gated(scope_boundaries(runs["boundaries"], diff), policy),
        diagnostics: diagnostics(runs)
      )
    end

    # Drop excluded-path observations; nil (a skipped analysis) passes through.
    def gated(observations, policy)
      return nil if observations.nil?

      observations.reject { |o| policy.excluded?(o.path) }
    end

    # Run one analysis in isolation (mirrors {Health.run}).
    def run
      Run.new(value: yield, error: nil)
    rescue => e
      Run.new(value: nil, error: e.message)
    end

    # ---- scoping (analysis findings -> pure, diff-filtered observations) -------

    # nil signals a skipped analysis (errored): its rule is not evaluated.
    def scope_complexity(run, diff)
      return nil unless run.ok?

      run.value.hotspots.flat_map do |hotspot|
        hotspot.methods.filter_map do |method|
          next unless diff.in_diff?(path: hotspot.path, start_line: method.span.start_line, end_line: method.span.end_line)

          Evaluation::ComplexityObs.new(
            symbol_id: method.symbol_id, path: hotspot.path,
            line: method.span.start_line, abc: method.abc
          )
        end
      end
    end

    def scope_dead_code(run, diff)
      return nil unless run.ok?

      run.value.findings.filter_map do |finding|
        next unless diff.in_diff?(path: finding.path, start_line: finding.span.start_line, end_line: finding.span.end_line)

        Evaluation::DeadCodeObs.new(
          symbol_id: finding.symbol_id, path: finding.path,
          line: finding.span.start_line, confidence: finding.confidence
        )
      end
    end

    # One observation per in-diff OCCURRENCE, so every site of a clone is visible
    # downstream. Mass stays a group property shared by all of them, and the
    # occurrences of one group share its clone_group join key.
    def scope_duplication(run, diff)
      return nil unless run.ok?

      run.value.findings.flat_map do |finding|
        finding.occurrences.filter_map do |occ|
          next unless diff.in_diff?(path: occ.path, start_line: occ.line, end_line: occ.line)

          Evaluation::DuplicationObs.new(
            symbol_id: occ.symbol_id, path: occ.path, line: occ.line,
            mass: finding.mass, clone_group: finding.clone_group
          )
        end
      end
    end

    # Boundaries are file-keyed (null symbol_id), so they scope at PATH granularity.
    # Skipped unless the project is actually packwerk-configured.
    def scope_boundaries(run, diff)
      return nil unless boundaries_contributes?(run)

      run.value.findings.flat_map do |finding|
        finding.occurrences.filter_map do |occ|
          next unless diff.includes_path?(occ.path)

          Evaluation::BoundaryObs.new(
            symbol_id: nil, path: occ.path, line: nil,
            severity: finding.severity, violation_type: finding.violation_type
          )
        end
      end
    end

    def boundaries_contributes?(run)
      run.ok? && run.value.configured
    end

    # ---- provenance -----------------------------------------------------------

    def diagnostics(runs)
      diags = {}
      %w[complexity dead_code duplication].each do |name|
        diags[name.to_sym] = runs[name].error if runs[name].error
      end
      unless boundaries_contributes?(runs["boundaries"])
        diags[:boundaries] = runs["boundaries"].error || "not a packwerk project (no packwerk.yml)"
      end
      diags
    end

    def component_views(runs)
      KNOWN_COMPONENTS.map do |name|
        present = (name == "boundaries") ? boundaries_contributes?(runs[name]) : runs[name].ok?
        diagnostic = present ? nil : component_diagnostic(name, runs[name])
        GateReport::Component.new(name: name, present: present, diagnostic: diagnostic)
      end
    end

    def component_diagnostic(name, run)
      return run.error if run.error
      return "not a packwerk project (no packwerk.yml)" if name == "boundaries"

      "analysis produced no result"
    end
  end
end

require_relative "gate/policy"
require_relative "gate/evaluation"
require_relative "gate/config"
require_relative "gate_report"
