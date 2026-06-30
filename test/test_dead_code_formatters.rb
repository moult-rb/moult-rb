# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

class TestDeadCodeFormatters < Minitest::Test
  def test_json_renders_schema_valid_output
    json = Moult::Formatters::DeadCodeJson.render(sample_deadcode_report)
    data = JSON.parse(json)
    errors = schemer("deadcode.schema.json").validate(data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_table_has_confidence_caveat_and_rows
    out = Moult::Formatters::DeadCodeTable.render(sample_deadcode_report)
    assert_includes out, "not certainties"
    assert_includes out, "User#stale"
    assert_includes out, "0.85"
    assert_includes out, "app/models/user.rb:7"
  end

  def test_table_handles_empty_report
    empty = Moult::DeadCodeReport.new(root: "/x", findings: [])
    assert_equal "No dead-code candidates found.", Moult::Formatters::DeadCodeTable.render(empty)
  end

  def test_table_top_reason_prefers_adjustment_over_base
    out = Moult::Formatters::DeadCodeTable.render(sample_deadcode_report)
    # The top reason is the last non-base adjustment (here, the runtime-cold
    # evidence), never the base_score line.
    assert_includes out, "runtime-cold corroborates"
    refute_includes out, "base for"
  end

  def test_table_shows_runtime_column_only_when_coverage_merged
    with = Moult::Formatters::DeadCodeTable.render(sample_deadcode_report)
    assert_includes with, "RUNTIME"
    assert_includes with, "cold"

    without = Moult::Formatters::DeadCodeTable.render(report_with_n_findings(2))
    refute_includes without, "RUNTIME", "no RUNTIME column without --coverage"
  end
end
