# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"
require "tmpdir"

# End-to-end over a real packwerk-structured fixture mini-repo: a packwerk.yml plus
# packages with committed package_todo.yml files capturing a dependency violation and
# a privacy violation. The adapter ingests packwerk's own on-disk serialization (no
# subprocess, no Rails boot), so the run is fully deterministic.
class TestBoundaries < Minitest::Test
  def build(min_severity: nil)
    Moult::Boundaries.build_report(root: fixture_path("boundaries"), min_severity: min_severity)
  end

  def test_project_is_detected_as_packwerk_configured
    report = build
    assert report.configured
    assert_equal "packwerk", report.backend
  end

  def test_finds_the_dependency_and_privacy_violations
    findings = build.findings
    assert_equal 3, findings.size
    assert_equal({"high" => 3, "medium" => 1}, build.summary[:by_severity])

    dependency = findings.find { |f| f.referencing_package == "packages/billing" }
    assert_equal "dependency", dependency.violation_type
    assert_equal "high", dependency.severity
    assert_equal "packages/user", dependency.defining_package
    assert_equal "::User::Account", dependency.constant

    privacy = findings.find { |f| f.violation_type == "privacy" }
    assert_equal "medium", privacy.severity
    assert_equal "::User::Token", privacy.constant
  end

  def test_a_multi_file_violation_groups_its_referencing_files
    dependency = build.findings.find { |f| f.referencing_package == "packages/billing" }
    paths = dependency.occurrences.map(&:path)
    assert_equal ["packages/billing/app/billing/charge.rb", "packages/billing/app/billing/invoice.rb"], paths
  end

  def test_occurrences_join_at_path_level_with_a_null_symbol_id
    build.findings.flat_map(&:occurrences).each do |occ|
      assert_kind_of String, occ.path
      assert_nil occ.symbol_id, "recorded packwerk violations are file-keyed: no enclosing method"
    end
  end

  def test_findings_are_sorted_most_severe_first
    severities = build.findings.map(&:severity)
    assert_equal severities.sort_by { |s| -Moult::Boundaries::Severity::SCALE.index(s) }, severities
  end

  def test_min_severity_filters_out_medium_and_below
    findings = build(min_severity: "high").findings
    refute_empty findings
    assert(findings.all? { |f| f.severity == "high" })
  end

  def test_an_unconfigured_project_yields_an_empty_configured_false_report
    Dir.mktmpdir do |root|
      File.write(File.join(root, "thing.rb"), "class Thing; end\n")
      report = Moult::Boundaries.build_report(root: root)
      refute report.configured
      assert_empty report.findings
      assert_equal 0, report.summary[:violations]
    end
  end

  def test_real_report_validates_against_the_schema
    schemer = schemer("boundaries.schema.json")
    data = JSON.parse(JSON.generate(build.to_h))
    errors = schemer.validate(data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end
end
