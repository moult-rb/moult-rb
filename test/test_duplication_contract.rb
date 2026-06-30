# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# The duplication JSON output contract is a protected API. These tests pin its
# shape and the invariant that every finding is a confidence-graded candidate in
# [0, 1] and never asserts that duplication is certainly removable.
class TestDuplicationContract < Minitest::Test
  def setup
    @schemer = schemer("duplication.schema.json")
    @data = JSON.parse(JSON.generate(sample_duplication_report.to_h))
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
    assert_equal "flay", detector["backend"]
    assert_equal 16, detector["min_mass"]
    assert_equal false, detector["fuzzy"]
    assert detector.key?("backend_version")
  end

  def test_summary_aggregates_across_findings
    summary = @data.fetch("summary")
    assert_equal 2, summary["sets"]
    assert_equal 4, summary["occurrences"]
    assert_equal 126, summary["total_mass"]
  end

  def test_every_finding_carries_category_confidence_kind_and_reasons
    @data.fetch("findings").each do |finding|
      assert_equal "duplication", finding["category"]
      assert_kind_of Numeric, finding["confidence"]
      assert_operator finding["confidence"], :>=, 0
      assert_operator finding["confidence"], :<=, 1
      assert_includes %w[identical similar], finding["kind"]
      assert_kind_of String, finding["node_type"]
      assert_kind_of Integer, finding["mass"]
      refute_empty finding.fetch("reasons")
      assert(finding["reasons"].all? { |r| r.key?("rule") && r.key?("delta") && r.key?("detail") })
    end
  end

  def test_occurrences_carry_a_nullable_symbol_id_join_key
    findings = @data.fetch("findings")
    attributed = findings.find { |f| f["kind"] == "identical" }["occurrences"]
    assert(attributed.all? { |o| o["symbol_id"].is_a?(String) })
    assert_equal "app/models/user.rb:7:User#normalize", attributed.first["symbol_id"]

    top_level = findings.find { |f| f["kind"] == "similar" }["occurrences"]
    assert(top_level.all? { |o| o["symbol_id"].nil? }, "top-level clones resolve to a null symbol_id")
  end

  def test_contract_never_asserts_certain_duplication
    finding = @data.fetch("findings").first
    refute finding.key?("removable"), "must never claim duplication is certainly removable"
    refute finding.key?("certain")
    refute finding.key?("dead")
    assert_equal "duplication", finding["category"]
  end

  def test_schema_rejects_unknown_top_level_keys
    refute_empty @schemer.validate(@data.merge("surprise" => true)).to_a
  end

  def test_schema_rejects_confidence_outside_unit_interval
    bad = JSON.parse(JSON.generate(sample_duplication_report.to_h))
    bad["findings"][0]["confidence"] = 1.5
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_null_confidence_on_a_finding
    bad = JSON.parse(JSON.generate(sample_duplication_report.to_h))
    bad["findings"][0]["confidence"] = nil
    refute_empty @schemer.validate(bad).to_a, "a duplication finding must assert a (non-null) confidence"
  end

  def test_schema_rejects_unknown_kind
    bad = JSON.parse(JSON.generate(sample_duplication_report.to_h))
    bad["findings"][0]["kind"] = "fuzzy"
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_a_single_occurrence_finding
    bad = JSON.parse(JSON.generate(sample_duplication_report.to_h))
    bad["findings"][0]["occurrences"] = [bad["findings"][0]["occurrences"].first]
    refute_empty @schemer.validate(bad).to_a, "a clone group needs at least two occurrences"
  end
end
