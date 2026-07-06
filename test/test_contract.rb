# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# The JSON output contract is a protected API. These tests pin its shape and
# the invariant that every finding reserves a confidence/category slot.
class TestContract < Minitest::Test
  def setup
    @schemer = schemer("hotspots.schema.json")
    # Round-trip through JSON so we validate string-keyed data, exactly what a
    # consumer parses off stdout.
    @data = JSON.parse(JSON.generate(sample_report.to_h))
  end

  def test_sample_report_validates_against_schema
    errors = @schemer.validate(@data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_envelope_carries_version_and_tool_metadata
    assert_equal 1, @data["schema_version"]
    assert_equal "moult", @data.dig("tool", "name")
    assert_equal Moult::VERSION, @data.dig("tool", "version")
  end

  def test_confidence_and_category_are_reserved_on_every_finding
    hotspot = @data.fetch("hotspots").first
    assert hotspot.key?("confidence"), "hotspot must reserve a confidence slot"
    assert hotspot.key?("category"), "hotspot must reserve a category slot"
    assert_nil hotspot["confidence"], "Phase 1 must not assert confidence"
    assert_nil hotspot["category"]

    method = hotspot.fetch("methods").first
    assert method.key?("confidence"), "method must reserve a confidence slot"
    assert method.key?("category"), "method must reserve a category slot"
    assert_nil method["confidence"], "Phase 1 must not assert confidence"
    assert_nil method["category"]
  end

  def test_method_carries_symbol_id_and_span
    method = @data.dig("hotspots", 0, "methods", 0)
    assert_equal "lib/foo.rb:10:Foo::Bar#baz", method["symbol_id"]
    assert_equal({"start_line" => 10, "start_column" => 2, "end_line" => 24, "end_column" => 5},
      method["span"])
  end

  def test_schema_rejects_unknown_top_level_keys
    bad = @data.merge("surprise" => true)
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_confidence_outside_unit_interval
    bad = JSON.parse(JSON.generate(sample_report.to_h))
    bad["hotspots"][0]["confidence"] = 1.5
    refute_empty @schemer.validate(bad).to_a
  end

  def test_populated_coupling_fields_validate
    hotspot = @data.fetch("hotspots").first
    assert_equal 2, hotspot["fan_in"]
    assert_equal 1, hotspot["fan_out"]
    assert_in_delta 0.33, hotspot["instability"], 0.001
  end

  # The additive-optional proof: a report built without coupling (the
  # untouched builder) must still validate against the same schema.
  def test_nil_coupling_report_still_validates
    data = JSON.parse(JSON.generate(report_with_n_hotspots(2).to_h))
    assert_empty @schemer.validate(data).to_a
    assert_nil data.dig("hotspots", 0, "fan_in")
  end

  def test_schema_rejects_bad_coupling_values
    bad = JSON.parse(JSON.generate(sample_report.to_h))
    bad["hotspots"][0]["instability"] = 1.5
    refute_empty @schemer.validate(bad).to_a

    bad = JSON.parse(JSON.generate(sample_report.to_h))
    bad["hotspots"][0]["fan_in"] = -1
    refute_empty @schemer.validate(bad).to_a
  end
end
