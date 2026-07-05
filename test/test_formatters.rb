# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

class TestJsonFormatter < Minitest::Test
  def test_output_validates_against_the_contract
    validator = schemer("hotspots.schema.json")
    json = Moult::Formatters::Json.render(sample_report)
    errors = validator.validate(JSON.parse(json)).to_a
    assert_empty errors, errors.map { |e| e["error"] }.join(", ")
  end

  def test_limit_truncates_hotspots
    report = report_with_n_hotspots(3)
    data = JSON.parse(Moult::Formatters::Json.render(report, limit: 2))
    assert_equal 2, data["hotspots"].size
  end

  def test_renders_pretty_json
    json = Moult::Formatters::Json.render(sample_report)
    assert_includes json, "\n  " # indentation present
  end
end

class TestTableFormatter < Minitest::Test
  def test_renders_headers_and_rows
    out = Moult::Formatters::Table.render(sample_report)
    assert_includes out, "SCORE"
    assert_includes out, "COMPLEXITY"
    assert_includes out, "CHURN"
    assert_includes out, "INST"
    assert_includes out, "0.33"
    assert_includes out, "lib/foo.rb"
    assert_includes out, "Foo::Bar#baz"
  end

  def test_nil_coupling_renders_dashes
    out = Moult::Formatters::Table.render(report_with_n_hotspots(1))
    row = out.lines.grep(/\A\s*1\s/).first
    assert_match(/-\s+-\s+-\s+f0\.rb/, row)
  end

  def test_empty_report_message
    empty = Moult::Report.new(root: "/x", hotspots: [])
    assert_equal "No hotspots found.", Moult::Formatters::Table.render(empty)
  end

  def test_heading_notes_when_limited
    report = report_with_n_hotspots(5)
    out = Moult::Formatters::Table.render(report, limit: 2)
    assert_includes out, "top 2 of 5"
    # only two data rows rendered (plus heading, blank line, header row)
    data_lines = out.lines.grep(/\A\s*\d+\s/)
    assert_equal 2, data_lines.size
  end
end
