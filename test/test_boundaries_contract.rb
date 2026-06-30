# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# The boundaries JSON output contract is a protected API. These tests pin its shape
# and the invariant that a finding is a SEVERITY-classified recorded fact carrying a
# null confidence — never a manufactured confidence and never a claim the code is
# certainly wrong.
class TestBoundariesContract < Minitest::Test
  def setup
    @schemer = schemer("boundaries.schema.json")
    @data = JSON.parse(JSON.generate(sample_boundaries_report.to_h))
  end

  def test_sample_report_validates_against_schema
    errors = @schemer.validate(@data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_envelope_carries_version_tool_and_detector_metadata
    assert_equal 1, @data["schema_version"]
    assert_equal "moult", @data.dig("tool", "name")
    assert_equal Moult::VERSION, @data.dig("tool", "version")
    detector = @data.dig("analysis", "detector")
    assert_equal "packwerk", detector["backend"]
    assert_equal true, detector["configured"]
    assert detector.key?("backend_version")
  end

  def test_summary_aggregates_across_findings
    summary = @data.fetch("summary")
    assert_equal 2, summary["findings"]
    assert_equal 3, summary["violations"]
    assert_equal 2, summary.dig("by_type", "dependency")
    assert_equal 1, summary.dig("by_type", "privacy")
    assert_equal 2, summary.dig("by_severity", "high")
    assert_equal 1, summary.dig("by_severity", "medium")
  end

  def test_every_finding_carries_category_null_confidence_severity_and_reasons
    @data.fetch("findings").each do |finding|
      assert_equal "architecture_boundary", finding["category"]
      assert_nil finding["confidence"], "a boundary violation is a recorded fact, not a graded guess"
      assert_includes %w[low medium high], finding["severity"]
      assert_includes %w[dependency privacy visibility folder_privacy layer], finding["violation_type"]
      assert_kind_of String, finding["referencing_package"]
      assert_kind_of String, finding["defining_package"]
      assert_kind_of String, finding["constant"]
      refute_empty finding.fetch("reasons")
      assert(finding["reasons"].all? { |r| r.key?("rule") && r.key?("detail") })
    end
  end

  def test_occurrences_carry_a_path_and_a_null_symbol_id_in_v1
    @data.fetch("findings").each do |finding|
      refute_empty finding["occurrences"]
      finding["occurrences"].each do |occ|
        assert_kind_of String, occ["path"]
        assert_nil occ["symbol_id"], "recorded packwerk violations are file-keyed; symbol_id is null in v1"
      end
    end
  end

  def test_contract_never_asserts_certainty_or_a_verdict
    finding = @data.fetch("findings").first
    refute finding.key?("certain")
    refute finding.key?("forbidden")
    refute finding.key?("pass")
    refute finding.key?("wrong")
    # confidence is present but null (the slot is reserved, honestly empty).
    assert finding.key?("confidence")
  end

  # ---- schema rejections ----------------------------------------------------

  def test_schema_rejects_unknown_top_level_keys
    refute_empty @schemer.validate(@data.merge("surprise" => true)).to_a
  end

  def test_model_always_emits_a_null_confidence
    # The always-null rule is a MODEL invariant (the schema's shared confidence slot
    # tolerates a unit-interval number); the report must never populate it.
    sample_boundaries_report.findings.each { |f| assert_nil f.to_h[:confidence] }
  end

  def test_schema_rejects_confidence_outside_the_unit_interval
    bad = JSON.parse(JSON.generate(sample_boundaries_report.to_h))
    bad["findings"][0]["confidence"] = 1.5
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_an_unknown_severity
    bad = JSON.parse(JSON.generate(sample_boundaries_report.to_h))
    bad["findings"][0]["severity"] = "critical"
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_an_unknown_violation_type
    bad = JSON.parse(JSON.generate(sample_boundaries_report.to_h))
    bad["findings"][0]["violation_type"] = "telepathy"
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_a_finding_with_no_occurrences
    bad = JSON.parse(JSON.generate(sample_boundaries_report.to_h))
    bad["findings"][0]["occurrences"] = []
    refute_empty @schemer.validate(bad).to_a, "a violation group needs at least one referencing site"
  end

  def test_schema_rejects_a_wrong_category
    bad = JSON.parse(JSON.generate(sample_boundaries_report.to_h))
    bad["findings"][0]["category"] = "duplication"
    refute_empty @schemer.validate(bad).to_a
  end
end
