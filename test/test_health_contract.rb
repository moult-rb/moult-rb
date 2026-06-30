# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# The health JSON output contract is a protected API. These tests pin its shape
# and the invariant that the composite is a confidence-graded SIGNAL — a score,
# a grade, and auditable component reasons — never a verdict (no pass/fail).
class TestHealthContract < Minitest::Test
  def setup
    @schemer = schemer("health.schema.json")
    @data = JSON.parse(JSON.generate(sample_health_report.to_h))
  end

  def test_sample_report_validates_against_schema
    errors = @schemer.validate(@data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_envelope_carries_version_tool_and_analysis
    assert_equal 1, @data["schema_version"]
    assert_equal "moult", @data.dig("tool", "name")
    assert_equal Moult::VERSION, @data.dig("tool", "version")
    assert @data["analysis"].key?("coverage")
    assert @data.dig("analysis", "churn").key?("window")
  end

  def test_overall_block_records_the_composite_and_degradation
    overall = @data.fetch("overall")
    assert_operator overall["score"], :>=, 0
    assert_operator overall["score"], :<=, 1
    assert_includes %w[A B C D F], overall["grade"]
    assert_equal 3, overall["components_present"]
    assert_equal 4, overall["components_total"]
    assert_equal 2, overall["files_total"]
  end

  def test_every_component_carries_name_category_weight_and_reasons
    names = @data.fetch("components").map { |c| c["name"] }
    assert_equal %w[complexity dead_code duplication coverage], names
    @data.fetch("components").each do |component|
      assert_kind_of String, component["name"]
      assert component.key?("category")
      assert_operator component["weight"], :>=, 0
      assert_operator component["weight"], :<=, 1
      assert component.key?("present")
      assert component.key?("reasons")
    end
  end

  def test_present_components_assert_a_unit_interval_score
    present = @data.fetch("components").select { |c| c["present"] }
    refute_empty present
    present.each do |component|
      assert_kind_of Numeric, component["score"]
      assert_operator component["score"], :>=, 0
      assert_operator component["score"], :<=, 1
      assert(component["reasons"].all? { |r| r.key?("rule") && r.key?("value") && r.key?("detail") })
      assert_nil component["diagnostic"]
    end
  end

  def test_absent_component_is_recorded_honestly_with_a_diagnostic
    coverage = @data.fetch("components").find { |c| c["name"] == "coverage" }
    refute coverage["present"]
    assert_nil coverage["score"]
    assert_nil coverage["normalized_weight"]
    assert_kind_of String, coverage["diagnostic"]
  end

  def test_files_join_via_symbol_ids
    files = @data.fetch("files")
    refute_empty files
    files.each do |file|
      assert_kind_of String, file["path"]
      assert_operator file["score"], :>=, 0
      assert_operator file["score"], :<=, 1
      assert_includes %w[A B C D F], file["grade"]
      assert(file["symbol_ids"].all? { |id| id.is_a?(String) })
      assert_operator file["symbol_count"], :>=, file["symbol_ids"].size
    end
    joined = files.first["symbol_ids"].first
    assert_equal "app/models/user.rb:7:User#stale", joined
  end

  def test_contract_never_asserts_a_verdict
    refute @data.key?("verdict"), "health is a graded signal, never a pass/fail verdict"
    refute @data.key?("pass")
    refute @data.dig("overall").key?("fail")
    refute @data.dig("overall").key?("healthy")
    @data.fetch("components").each do |component|
      refute component.key?("pass"), "a component is a graded sub-score, not a gate"
      refute component.key?("healthy")
    end
  end

  # ---- schema rejections ----------------------------------------------------

  def test_schema_rejects_unknown_top_level_keys
    refute_empty @schemer.validate(@data.merge("surprise" => true)).to_a
  end

  def test_schema_rejects_a_component_score_outside_the_unit_interval
    bad = JSON.parse(JSON.generate(sample_health_report.to_h))
    bad["components"][0]["score"] = 1.5
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_rejects_an_unknown_grade
    bad = JSON.parse(JSON.generate(sample_health_report.to_h))
    bad["overall"]["grade"] = "Z"
    refute_empty @schemer.validate(bad).to_a
  end

  def test_schema_allows_a_null_composite_when_nothing_ran
    bare = JSON.parse(JSON.generate(sample_health_report.to_h))
    bare["overall"]["score"] = nil
    bare["overall"]["grade"] = nil
    assert_empty @schemer.validate(bare).to_a, "score/grade are nullable when no component ran"
  end
end
