# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# The flags JSON output contract is a protected API. These tests pin its shape and
# the invariant that a finding is a CLASSIFIED recorded usage fact carrying a null
# confidence — never a manufactured confidence and never a claim a flag is stale,
# dead, or unused.
class TestFlagsContract < Minitest::Test
  def setup
    @schemer = schemer("flags.schema.json")
    @data = JSON.parse(JSON.generate(sample_flags_report.to_h))
  end

  def test_sample_report_validates_against_schema
    errors = @schemer.validate(@data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_envelope_carries_version_tool_and_scanner_provenance
    assert_equal 1, @data["schema_version"]
    assert_equal "moult", @data.dig("tool", "name")
    assert_equal Moult::VERSION, @data.dig("tool", "version")
    scanner = @data.dig("analysis", "scanner")
    assert_equal "openfeature", scanner["target"]
    assert_equal "openfeature-sdk", scanner["sdk_gem"]
    assert_equal "OpenFeature::SDK.build_client", scanner["client_builder"]
  end

  def test_summary_aggregates_across_findings
    summary = @data.fetch("summary")
    assert_equal 2, summary["flags"]
    assert_equal 3, summary["references"]
    assert_equal 1, summary["dynamic_references"]
    assert_equal 2, summary.dig("by_value_type", "boolean")
    assert_equal 1, summary.dig("by_value_type", "string")
  end

  def test_every_finding_carries_category_null_confidence_and_classification
    @data.fetch("findings").each do |finding|
      assert_equal "feature_flag", finding["category"]
      assert_nil finding["confidence"], "a flag reference is a recorded fact, not a graded guess"
      assert_includes %w[boolean string number object unknown], finding["value_type"]
      assert_kind_of String, finding["flag_key"]
      assert_operator finding["reference_count"], :>=, 1
      assert_kind_of Array, finding["default_values"]
      refute_empty finding.fetch("reasons")
      assert(finding["reasons"].all? { |r| r.key?("rule") && r.key?("detail") })
    end
  end

  def test_reference_count_equals_occurrence_count
    @data.fetch("findings").each do |finding|
      assert_equal finding["occurrences"].size, finding["reference_count"]
    end
  end

  def test_occurrences_carry_a_nullable_symbol_id_and_a_method
    occ = @data.fetch("findings").flat_map { |f| f["occurrences"] }
    assert(occ.any? { |o| o["symbol_id"].is_a?(String) }, "expected at least one in-method reference")
    assert(occ.any? { |o| o["symbol_id"].nil? }, "expected at least one top-level reference")
    occ.each do |o|
      assert_kind_of String, o["path"]
      assert_kind_of Integer, o["line"]
      assert_kind_of String, o["method"]
    end
  end

  def test_contract_never_asserts_staleness_or_death
    finding = @data.fetch("findings").first
    refute finding.key?("stale")
    refute finding.key?("dead")
    refute finding.key?("unused")
    refute finding.key?("obsolete")
    # confidence is present but null (the slot is reserved, honestly empty).
    assert finding.key?("confidence")
  end

  # ---- schema rejections ----------------------------------------------------

  def test_schema_rejects_unknown_top_level_keys
    refute_empty @schemer.validate(@data.merge("surprise" => true)).to_a
  end

  def test_model_always_emits_a_null_confidence
    sample_flags_report.findings.each { |f| assert_nil f.to_h[:confidence] }
  end

  def test_schema_rejects_confidence_outside_the_unit_interval
    bad = JSON.parse(JSON.generate(sample_flags_report.to_h))
    bad["findings"][0]["confidence"] = 1.5
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_an_unknown_value_type
    bad = JSON.parse(JSON.generate(sample_flags_report.to_h))
    bad["findings"][0]["value_type"] = "datetime"
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_a_wrong_category
    bad = JSON.parse(JSON.generate(sample_flags_report.to_h))
    bad["findings"][0]["category"] = "duplication"
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_a_finding_with_no_occurrences
    bad = JSON.parse(JSON.generate(sample_flags_report.to_h))
    bad["findings"][0]["occurrences"] = []
    refute_empty @schemer.validate(bad).to_a, "a flag finding needs at least one reference site"
  end

  # ---- v2: staleness via a merged provider snapshot -------------------------

  def test_v2_sample_with_provider_validates_against_schema
    data = JSON.parse(JSON.generate(sample_flags_staleness_report.to_h))
    errors = @schemer.validate(data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_v2_envelope_reports_version_2_and_provider_provenance
    data = JSON.parse(JSON.generate(sample_flags_staleness_report.to_h))
    assert_equal 2, data["schema_version"]
    provider = data.dig("analysis", "provider")
    assert_equal "flagd", provider["backend"]
    assert_equal "42", provider["version"]
    assert provider.key?("exported_at")
  end

  def test_v2_findings_populate_the_confidence_slot_from_staleness
    data = JSON.parse(JSON.generate(sample_flags_staleness_report.to_h))
    data.fetch("findings").each do |finding|
      stale = finding.fetch("staleness")
      assert_includes %w[archived absent disabled rolled_out active], stale["status"]
      assert_operator stale["confidence"], :>=, 0.0
      assert_operator stale["confidence"], :<=, 1.0
      # The reserved confidence slot mirrors the staleness candidate's confidence —
      # its first real use in this contract.
      assert_equal stale["confidence"], finding["confidence"]
      refute_empty stale.fetch("reasons")
    end
  end

  def test_v2_summary_tallies_by_staleness_status
    data = JSON.parse(JSON.generate(sample_flags_staleness_report.to_h))
    tally = data.dig("summary", "by_staleness_status")
    assert_kind_of Hash, tally
    assert_equal 1, tally["rolled_out"]
    assert_equal 1, tally["absent"]
  end

  def test_v2_never_asserts_certain_death
    data = JSON.parse(JSON.generate(sample_flags_staleness_report.to_h))
    serialized = JSON.generate(data)
    refute_match(/\b(dead|unused|obsolete)\b/i, serialized,
      "the staleness contract must stay a confidence-graded candidate, never a death claim")
  end

  # ---- the additive bump is safe: no snapshot == byte-for-byte v1 -----------

  def test_without_a_snapshot_the_output_is_byte_for_byte_v1
    h = sample_flags_report.to_h
    assert_equal 1, h[:schema_version]
    refute h[:analysis].key?(:provider), "no provider block without a snapshot"
    refute h[:summary].key?(:by_staleness_status), "no staleness tally without a snapshot"
    h[:findings].each do |finding|
      assert_nil finding[:confidence]
      refute finding.key?(:staleness), "no staleness block without a snapshot"
    end
  end

  def test_a_v1_finding_serializes_the_exact_v1_key_set
    finding = sample_flags_report.findings.first.to_h
    assert_equal %i[category confidence flag_key value_type reference_count default_values reasons occurrences],
      finding.keys
  end
end
