# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# The dead-code JSON output contract is a protected API. These tests pin its
# shape and the invariant that every finding carries a confidence in [0, 1] and
# never asserts certain death.
class TestDeadcodeContract < Minitest::Test
  def setup
    @schemer = schemer("deadcode.schema.json")
    @data = JSON.parse(JSON.generate(sample_deadcode_report.to_h))
  end

  def test_sample_report_validates_against_schema
    errors = @schemer.validate(@data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_envelope_carries_version_tool_and_index_metadata
    assert_equal 2, @data["schema_version"]
    assert_equal "moult", @data.dig("tool", "name")
    assert_equal Moult::VERSION, @data.dig("tool", "version")
    assert_equal "rubydex", @data.dig("analysis", "index", "backend")
    assert_equal true, @data.dig("analysis", "index", "resolved")
  end

  def test_analysis_carries_coverage_source_when_merged
    coverage = @data.dig("analysis", "coverage")
    assert_equal "simplecov", coverage["backend"]
    assert coverage.key?("version")
    assert coverage.key?("collected_at")
  end

  def test_finding_carries_runtime_classification
    finding = @data.fetch("findings").first
    assert finding.key?("runtime"), "v2 findings carry a runtime slot"
    assert_includes %w[hot cold untracked], finding["runtime"]
    assert(finding["reasons"].any? { |r| r["rule"] == "runtime_cold" })
  end

  def test_no_coverage_run_emits_null_runtime_block
    report = sample_deadcode_report
    report.findings.first.runtime = nil
    report.instance_variable_set(:@coverage_source, nil)
    data = JSON.parse(JSON.generate(report.to_h))
    assert_empty @schemer.validate(data).to_a, "null coverage/runtime must still validate"
    assert_nil data.dig("analysis", "coverage")
    assert_nil data.dig("findings", 0, "runtime")
  end

  def test_schema_rejects_unknown_runtime_value
    bad = JSON.parse(JSON.generate(sample_deadcode_report.to_h))
    bad["findings"][0]["runtime"] = "warm"
    refute_empty @schemer.validate(bad).to_a
  end

  def test_every_finding_carries_confidence_category_and_reasons
    finding = @data.fetch("findings").first
    assert finding.key?("confidence")
    assert_kind_of Numeric, finding["confidence"]
    assert_operator finding["confidence"], :>=, 0
    assert_operator finding["confidence"], :<=, 1
    assert_equal "dead_code", finding["category"]
    refute_empty finding.fetch("reasons")
    assert(finding["reasons"].all? { |r| r.key?("rule") && r.key?("delta") && r.key?("detail") })
  end

  def test_contract_never_asserts_certain_death
    finding = @data.fetch("findings").first
    refute finding.key?("dead"), "must never claim certain death"
    refute finding.key?("certain")
    assert_equal "dead_code", finding["category"]
  end

  def test_finding_carries_symbol_id_kind_and_span
    finding = @data.dig("findings", 0)
    assert_equal "app/models/user.rb:7:User#stale", finding["symbol_id"]
    assert_includes %w[method constant], finding["kind"]
    assert_equal({"start_line" => 7, "start_column" => 2, "end_line" => 9, "end_column" => 5}, finding["span"])
  end

  def test_schema_rejects_unknown_top_level_keys
    bad = @data.merge("surprise" => true)
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_confidence_outside_unit_interval
    bad = JSON.parse(JSON.generate(sample_deadcode_report.to_h))
    bad["findings"][0]["confidence"] = 1.5
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_null_confidence_on_a_finding
    bad = JSON.parse(JSON.generate(sample_deadcode_report.to_h))
    bad["findings"][0]["confidence"] = nil
    refute_empty @schemer.validate(bad).to_a, "a dead-code finding must assert a (non-null) confidence"
  end

  def test_schema_rejects_unknown_kind
    bad = JSON.parse(JSON.generate(sample_deadcode_report.to_h))
    bad["findings"][0]["kind"] = "class"
    refute_empty @schemer.validate(bad).to_a
  end
end
