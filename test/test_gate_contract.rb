# frozen_string_literal: true

require_relative "test_helper"

# Validates the serialized gate report against schema/gate.schema.json and pins the
# invariants that make the gate honest: it is the ONLY contract that renders a
# verdict, the policy it applied is recorded in full, and contributing findings stay
# confidence-graded candidates (never claims of certainty).
class TestGateContract < Minitest::Test
  def setup
    @schemer = schemer("gate.schema.json")
    @data = JSON.parse(JSON.generate(sample_gate_report.to_h))
  end

  def test_sample_report_validates_against_schema
    errors = @schemer.validate(@data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_envelope_carries_version_tool_and_diff_provenance
    assert_equal 1, @data["schema_version"]
    assert_equal "moult", @data.dig("tool", "name")
    assert_equal Moult::VERSION, @data.dig("tool", "version")
    analysis = @data.fetch("analysis")
    assert_equal "origin/main", analysis["base_ref"]
    assert_equal "0123abcdef", analysis["merge_base"]
    assert_equal "diff", analysis["scope"]
    assert analysis.key?("components")
  end

  def test_components_record_which_analyses_ran
    names = @data.dig("analysis", "components").map { |c| c["name"] }
    assert_equal %w[complexity dead_code duplication boundaries], names
    boundaries = @data.dig("analysis", "components").find { |c| c["name"] == "boundaries" }
    refute boundaries["present"]
    refute_nil boundaries["diagnostic"]
  end

  def test_policy_is_recorded_in_full
    policy = @data.fetch("policy")
    assert_equal "default", policy["source"]
    assert_equal 0.8, policy["dead_code_max_confidence"]
    assert_equal "medium", policy["boundary_max_severity"]
    assert_equal 30.0, policy["complexity_ceiling"]
    assert_equal 100, policy["duplication_max_mass"]
    assert_equal %w[test spec], policy["exclude_paths"]
  end

  def test_verdict_is_present_and_is_pass_or_fail
    assert_includes %w[pass fail], @data["verdict"]
    assert_equal "fail", @data["verdict"], "the sample has a high-confidence new dead-code candidate"
    refute_empty @data.fetch("reasons")
  end

  def test_each_rule_records_outcome_threshold_and_findings
    rules = @data.fetch("rules")
    assert_equal 4, rules.size
    rules.each do |rule|
      assert_includes %w[no_new_dead_code no_new_high_severity_boundary new_code_complexity_ceiling new_code_duplication_ceiling], rule["rule"]
      assert rule.key?("evaluated")
      assert rule.key?("observed")
      assert rule.key?("threshold")
      assert rule.key?("passed")
      assert rule.key?("findings")
    end
  end

  def test_skipped_rule_never_fails_the_gate
    boundary = @data.fetch("rules").find { |r| r["rule"] == "no_new_high_severity_boundary" }
    refute boundary["evaluated"]
    assert_nil boundary["passed"], "a rule whose analysis didn't run is not evaluated, so not failed"
    assert_empty boundary["findings"]
  end

  def test_contributing_findings_stay_graded_candidates
    failed = @data.fetch("rules").find { |r| r["rule"] == "no_new_dead_code" }
    assert_equal false, failed["passed"]
    refute_empty failed["findings"]
    finding = failed["findings"].first
    assert_equal "dead_code", finding["category"]
    assert_equal "app/models/user.rb", finding["path"]
    assert_equal 7, finding["line"]
    assert_in_delta 0.85, finding["value"], 0.0001
  end

  def test_duplication_findings_share_a_clone_group_and_count_as_one
    dup = @data.fetch("rules").find { |r| r["rule"] == "new_code_duplication_ceiling" }
    assert_equal false, dup["passed"]
    assert_equal 2, dup["findings"].size, "each occurrence of the clone is its own contribution"
    assert_equal ["identical:190423"], dup["findings"].map { |f| f["clone_group"] }.uniq
    assert_match(/\A1 clone group/, dup["reasons"].first["detail"], "reasons count groups, not occurrences")
  end

  def test_clone_group_is_null_outside_duplication
    dead = @data.fetch("rules").find { |r| r["rule"] == "no_new_dead_code" }
    assert dead["findings"].first.key?("clone_group")
    assert_nil dead["findings"].first["clone_group"]
  end

  # The whole point of the separation: a verdict lives here and ONLY here. No
  # signal contract may grow a pass/fail.
  def test_verdict_appears_only_in_the_gate_contract
    %w[health.schema.json boundaries.schema.json flags.schema.json
      deadcode.schema.json duplication.schema.json coverage.schema.json
      hotspots.schema.json].each do |name|
      text = File.read(File.join(TestHelpers::SCHEMA_DIR, name))
      refute_match(/"verdict"/, text, "#{name} must not carry a verdict")
    end
    assert_match(/"verdict"/, File.read(File.join(TestHelpers::SCHEMA_DIR, "gate.schema.json")))
  end

  def test_nothing_claims_certain_death_or_wrongness
    json = JSON.generate(@data).downcase
    refute_includes json, "certainly"
    refute_includes json, "definitely dead"
    refute_includes json, "is dead"
  end

  def test_schema_rejects_unknown_top_level_keys
    refute_empty @schemer.validate(@data.merge("surprise" => true)).to_a
  end
end
