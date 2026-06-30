# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# The coverage-map JSON output is a typed contract. These tests pin its shape and
# the invariant that it reports runtime classification only — never a dead-code
# claim.
class TestCoverageContract < Minitest::Test
  def setup
    @schemer = schemer("coverage.schema.json")
    @data = JSON.parse(JSON.generate(sample_coverage_report.to_h))
  end

  def sample_coverage_report
    Moult::CoverageReport.new(
      root: "/abs/project",
      entries: [
        Moult::CoverageReport::Entry.new(
          symbol_id: "lib/a.rb:3:A#run", kind: :method, name: "A#run",
          span: Moult::Span.new(start_line: 3, start_column: 2, end_line: 6, end_column: 5),
          runtime: :hot
        ),
        Moult::CoverageReport::Entry.new(
          symbol_id: "lib/a.rb:8:A#stale", kind: :method, name: "A#stale",
          span: Moult::Span.new(start_line: 8, start_column: 2, end_line: 10, end_column: 5),
          runtime: :cold
        ),
        Moult::CoverageReport::Entry.new(
          symbol_id: "lib/a.rb:1:A::VERSION", kind: :constant, name: "A::VERSION",
          span: Moult::Span.new(start_line: 1, start_column: 0, end_line: 1, end_column: 20),
          runtime: :untracked
        )
      ],
      git_ref: "0123abc",
      generated_at: "2026-06-29T12:00:00Z",
      backend_version: "0.2.6",
      coverage_source: Moult::Coverage::Source.new(
        backend: "coverage", version: RUBY_VERSION, collected_at: "2026-06-29T11:00:00Z"
      )
    )
  end

  def test_sample_validates_against_schema
    errors = @schemer.validate(@data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_envelope_and_summary
    assert_equal 1, @data["schema_version"]
    assert_equal "moult", @data.dig("tool", "name")
    assert_equal "coverage", @data.dig("analysis", "coverage", "backend")
    assert_equal({"hot" => 1, "cold" => 1, "untracked" => 1}, @data["summary"])
  end

  def test_symbols_carry_join_key_and_runtime
    sym = @data.fetch("symbols").first
    assert sym.key?("symbol_id")
    assert_includes %w[hot cold untracked], sym["runtime"]
  end

  def test_contract_makes_no_dead_code_claim
    refute @data.key?("findings")
    @data.fetch("symbols").each do |s|
      refute s.key?("confidence")
      refute s.key?("dead")
    end
  end

  def test_schema_rejects_unknown_runtime
    bad = JSON.parse(JSON.generate(sample_coverage_report.to_h))
    bad["symbols"][0]["runtime"] = "warm"
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_null_runtime_in_map
    bad = JSON.parse(JSON.generate(sample_coverage_report.to_h))
    bad["symbols"][0]["runtime"] = nil
    refute_empty @schemer.validate(bad).to_a, "the map always classifies; null is not allowed here"
  end
end
