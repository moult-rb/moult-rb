# frozen_string_literal: true

require "test_helper"
require "json"

# Pins the serialized cycles contract to schema/cycles.schema.json: the sample
# report validates, and representative bad shapes are rejected.
class TestCyclesContract < Minitest::Test
  def setup
    @schemer = schemer("cycles.schema.json")
    @data = JSON.parse(JSON.generate(sample_cycles_report.to_h))
  end

  def test_sample_report_validates
    assert_empty @schemer.validate(@data).to_a
  end

  def test_envelope_carries_version_tool_and_index
    assert_equal 1, @data["schema_version"]
    assert_equal "moult", @data.dig("tool", "name")
    assert_equal "rubydex", @data.dig("analysis", "index", "backend")
  end

  def test_summary_counts_the_sample
    assert_equal({"cycles" => 1, "files" => 2, "largest" => 2}, @data["summary"])
  end

  def test_rejects_unknown_top_level_key
    @data["extra"] = 1
    refute_empty @schemer.validate(@data).to_a
  end

  def test_rejects_out_of_range_confidence
    @data["findings"][0]["confidence"] = 1.5
    refute_empty @schemer.validate(@data).to_a
  end

  def test_rejects_null_confidence
    @data["findings"][0]["confidence"] = nil
    refute_empty @schemer.validate(@data).to_a
  end

  def test_rejects_single_file_cycle
    @data["findings"][0]["size"] = 1
    refute_empty @schemer.validate(@data).to_a

    @data["findings"][0]["size"] = 2
    @data["findings"][0]["files"] = ["a.rb"]
    refute_empty @schemer.validate(@data).to_a
  end

  def test_rejects_bad_cycle_group_prefix
    @data["findings"][0]["cycle_group"] = "x:abc"
    refute_empty @schemer.validate(@data).to_a
  end
end
