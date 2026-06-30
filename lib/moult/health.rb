# frozen_string_literal: true

module Moult
  # Orchestrates the health score: it runs each existing analysis, extracts the
  # numeric signals each one exposes, and composes them through the pure
  # {Health::Score} model into one auditable {HealthReport}. There is no external
  # tool here — the "adapter" is this composition of Moult's own reports.
  #
  # This is the only layer that does IO and knows how the signals are sourced;
  # {Score} stays a pure function of the extracted numbers so it can be pinned in
  # isolation. Every analysis is run inside its own rescue: a failure degrades that
  # one component to `present: false` with a diagnostic, never crashing the whole
  # health run.
  module Health
    # Fixed component order, so output is stable and every slot is accounted for
    # (present, skipped, or errored).
    KNOWN_COMPONENTS = %w[complexity dead_code duplication coverage boundaries].freeze

    # Cap on join keys serialized per file, so the roll-up cannot balloon on a
    # large file; the true total is recorded alongside.
    SYMBOLS_PER_FILE = 20

    # The outcome of one isolated analysis run.
    Run = Struct.new(:value, :error) do
      def ok?
        error.nil? && !value.nil?
      end
    end

    module_function

    # @param root [String] absolute analysis root
    # @param files [Array<String>] absolute Ruby file paths to analyse
    # @param index [Index] resolved definition/reference index (drives dead-code + coverage)
    # @param rails [RailsConventions] Rails entrypoint awareness for dead-code
    # @param coverage [Coverage::Dataset, nil] runtime coverage to merge (adds the coverage component)
    # @param since [String, nil] churn window start for the complexity component
    # @return [HealthReport]
    def build_report(root:, files:, index:, rails:, coverage: nil, since: nil,
      git_ref: nil, generated_at: nil, churn_window: nil, churn_since: nil)
      churn = Churn.collect(root: root, since: since || Churn::DEFAULT_SINCE)

      runs = {
        "complexity" => run { Scoring.build_report(root: root, files: files, churn: churn) },
        "dead_code" => run { DeadCode.build_report(root: root, files: files, index: index, rails: rails, coverage: coverage) },
        "duplication" => run { Duplication.build_report(root: root, files: files) },
        "coverage" => run { coverage ? CoverageReport.build(index: index, coverage: coverage, root: root) : nil },
        "boundaries" => run { Boundaries.build_report(root: root) }
      }

      # Derive churn presence from the JOINED hotspots, not the raw churn hash: a
      # repo-relative churn map run against a subdir root won't join to the scored
      # files, so the honest signal is "did any scored file actually carry churn".
      churn_present = runs["complexity"].ok? &&
        runs["complexity"].value.hotspots.any? { |h| h.churn.to_i.positive? }

      inputs = Score::Inputs.new(
        complexity: runs["complexity"].ok? ? complexity_input(runs["complexity"].value, churn_present) : nil,
        dead_code: runs["dead_code"].ok? ? dead_code_input(runs["dead_code"].value, index) : nil,
        duplication: runs["duplication"].ok? ? duplication_input(runs["duplication"].value, files.size) : nil,
        coverage: runs["coverage"].ok? ? coverage_input(runs["coverage"].value) : nil,
        # Absent (skipped) unless the project is actually packwerk-configured: an
        # unconfigured repo has no boundary signal and must not read as healthy 1.0.
        boundaries: boundaries_present?(runs["boundaries"]) ? boundaries_input(runs["boundaries"].value, files.size) : nil
      )

      composite = Score.assess(inputs)
      components = component_views(composite, runs, coverage_requested: !coverage.nil?)
      files_view = file_rollup(runs, index, churn_present)

      HealthReport.new(
        root: root,
        score: composite.score,
        grade: composite.grade,
        components: components,
        files: files_view,
        git_ref: git_ref,
        generated_at: generated_at,
        coverage_source: coverage&.source,
        churn_window: churn_window,
        churn_since: churn_since
      )
    end

    # Run one analysis in isolation: success carries the report, any failure
    # carries the message so the component degrades rather than the whole run.
    def run
      Run.new(value: yield, error: nil)
    rescue => e
      Run.new(value: nil, error: e.message)
    end

    # ---- signal extraction (heavy report -> pure numeric input) ---------------

    def complexity_input(report, churn_present)
      hs = report.hotspots
      Score::ComplexityInput.new(
        file_count: hs.size,
        total_complexity: hs.sum(&:complexity),
        total_score: hs.sum(&:score),
        churn_present: churn_present
      )
    end

    def dead_code_input(report, index)
      Score::DeadCodeInput.new(
        symbol_count: index.definitions.size,
        confidence_sum: report.findings.sum(&:confidence),
        finding_count: report.findings.size,
        resolved: report.resolved
      )
    end

    def duplication_input(report, file_count)
      # Only the EXTRA copies are consolidatable mass; confidence-weight so a
      # low-confidence "similar" rhyme barely registers.
      weighted = report.findings.sum { |f| f.confidence * f.mass * (f.occurrences.size - 1) }
      Score::DuplicationInput.new(
        file_count: file_count,
        weighted_dup_mass: weighted,
        set_count: report.findings.size
      )
    end

    def coverage_input(report)
      s = report.summary
      Score::CoverageInput.new(hot: s[:hot], cold: s[:cold])
    end

    # A boundaries run contributes only when it ran AND the project is packwerk-
    # configured; an unconfigured repo yields a successful-but-empty report that
    # must be SKIPPED, not scored as vacuously healthy.
    def boundaries_present?(run)
      run.ok? && run.value.configured
    end

    def boundaries_input(report, file_count)
      Score::BoundariesInput.new(
        file_count: file_count,
        weighted_violations: report.findings.sum { |f| boundary_weight(f) * f.occurrences.size },
        violation_count: report.findings.sum { |f| f.occurrences.size }
      )
    end

    def boundary_weight(finding)
      Boundaries::Severity::SEVERITY_WEIGHT.fetch(finding.severity, Boundaries::Severity::SEVERITY_WEIGHT.fetch("low"))
    end

    # ---- component views (every slot, present or not) -------------------------

    def component_views(composite, runs, coverage_requested:)
      present = composite.components.to_h { |c| [c.name, c] }
      present_names = composite.components.map(&:name)

      KNOWN_COMPONENTS.map do |name|
        component = present[name]
        if component
          HealthReport::ComponentView.new(
            name: name,
            category: component.category,
            present: true,
            score: component.score,
            weight: Score::WEIGHTS.fetch(name),
            normalized_weight: Score.normalized_weight(name, present_names),
            summary: component.stats,
            reasons: component.reasons,
            diagnostic: nil
          )
        else
          HealthReport::ComponentView.new(
            name: name,
            category: nil,
            present: false,
            score: nil,
            weight: Score::WEIGHTS.fetch(name),
            normalized_weight: nil,
            summary: {},
            reasons: [],
            diagnostic: diagnostic_for(name, runs[name], coverage_requested)
          )
        end
      end
    end

    def diagnostic_for(name, run, coverage_requested)
      return run.error if run&.error
      case name
      when "coverage"
        coverage_requested ? "coverage produced no usable signal" : "no --coverage supplied"
      when "boundaries"
        "not a packwerk project (no packwerk.yml)"
      else
        "analysis produced no result"
      end
    end

    # ---- per-file roll-up (the cross-analysis join surface) -------------------

    def file_rollup(runs, index, churn_present)
      hotspots = runs["complexity"].ok? ? runs["complexity"].value.hotspots.to_h { |h| [h.path, h] } : {}
      dead = runs["dead_code"].ok? ? runs["dead_code"].value.findings.group_by(&:path) : {}
      dup = runs["duplication"].ok? ? clones_by_path(runs["duplication"].value) : {}
      cov = runs["coverage"].ok? ? coverage_by_path(runs["coverage"].value) : {}
      bnd = boundaries_present?(runs["boundaries"]) ? boundaries_by_path(runs["boundaries"].value) : {}
      symbols_per_file = index.definitions.group_by(&:path).transform_values(&:size)

      paths = Set.new
      paths.merge(hotspots.keys)
      paths.merge(dead.keys)
      paths.merge(dup.keys)
      paths.merge(cov.select { |_, c| c[:cold].positive? }.keys)
      paths.merge(bnd.keys)

      views = paths.map do |path|
        file_view(path, hotspots[path], dead[path], dup[path], cov[path], bnd[path],
          symbols_per_file[path], churn_present)
      end
      # Least-healthy first, path as a deterministic tie-break.
      views.sort_by { |v| [v.score, v.path] }
    end

    def file_view(path, hotspot, dead_findings, clone, coverage, boundaries, symbol_count, churn_present)
      inputs = Score::Inputs.new(
        complexity: hotspot && Score::ComplexityInput.new(
          file_count: 1, total_complexity: hotspot.complexity,
          total_score: hotspot.score, churn_present: churn_present
        ),
        dead_code: dead_findings && Score::DeadCodeInput.new(
          symbol_count: [symbol_count.to_i, dead_findings.size].max,
          confidence_sum: dead_findings.sum(&:confidence),
          finding_count: dead_findings.size, resolved: true
        ),
        duplication: clone && Score::DuplicationInput.new(
          file_count: 1, weighted_dup_mass: clone[:weighted_mass], set_count: clone[:sets]
        ),
        coverage: coverage && tracked?(coverage) && Score::CoverageInput.new(
          hot: coverage[:hot], cold: coverage[:cold]
        ),
        boundaries: boundaries && Score::BoundariesInput.new(
          file_count: 1, weighted_violations: boundaries[:weighted], violation_count: boundaries[:count]
        )
      )

      composite = Score.assess(inputs)
      ids = file_symbol_ids(hotspot, dead_findings, clone, coverage)
      HealthReport::FileView.new(
        path: path,
        score: composite.score,
        grade: composite.grade,
        components: composite.components.to_h { |c| [c.name, c.score] },
        symbol_ids: ids.first(SYMBOLS_PER_FILE),
        symbol_count: ids.size
      )
    end

    # Contributing join keys for a file, dead-finding / clone / coverage / hotspot
    # in that order, de-duplicated.
    def file_symbol_ids(hotspot, dead_findings, clone, coverage)
      ids = []
      ids.concat(dead_findings.map(&:symbol_id)) if dead_findings
      ids.concat(clone[:symbol_ids]) if clone
      ids.concat(coverage[:cold_ids]) if coverage
      ids.concat(hotspot.methods.map(&:symbol_id)) if hotspot
      ids.compact.uniq
    end

    def tracked?(coverage)
      (coverage[:hot] + coverage[:cold]).positive?
    end

    # path => {weighted_mass:, sets:, symbol_ids:} from clone occurrences in that file.
    def clones_by_path(report)
      acc = Hash.new { |h, k| h[k] = {weighted_mass: 0.0, sets: 0, symbol_ids: []} }
      report.findings.each do |finding|
        finding.occurrences.each do |occ|
          bucket = acc[occ.path]
          bucket[:weighted_mass] += finding.confidence * finding.mass
          bucket[:sets] += 1
          bucket[:symbol_ids] << occ.symbol_id if occ.symbol_id
        end
      end
      acc.default_proc = nil # so later missing-key reads return nil instead of mutating
      acc
    end

    # path => {weighted:, count:} from boundary-violation occurrences in that file.
    # Boundary occurrences carry a null symbol_id (file-keyed), so they contribute to
    # the per-file roll-up at PATH granularity only — never to file_symbol_ids.
    def boundaries_by_path(report)
      acc = Hash.new { |h, k| h[k] = {weighted: 0.0, count: 0} }
      report.findings.each do |finding|
        weight = boundary_weight(finding)
        finding.occurrences.each do |occ|
          acc[occ.path][:weighted] += weight
          acc[occ.path][:count] += 1
        end
      end
      acc.default_proc = nil # so later missing-key reads return nil instead of mutating
      acc
    end

    # path => {hot:, cold:, cold_ids:} from coverage entries (path parsed from symbol_id).
    def coverage_by_path(report)
      acc = Hash.new { |h, k| h[k] = {hot: 0, cold: 0, cold_ids: []} }
      report.entries.each do |entry|
        path = entry.symbol_id.split(":", 3).first
        case entry.runtime
        when :hot then acc[path][:hot] += 1
        when :cold
          acc[path][:cold] += 1
          acc[path][:cold_ids] << entry.symbol_id
        end
      end
      acc.default_proc = nil # so later missing-key reads return nil instead of mutating
      acc
    end
  end
end

require_relative "health/score"
