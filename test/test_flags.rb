# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# End-to-end over real Ruby source fixtures exercising the OpenFeature client API.
# Drives the whole slice: scan -> group by key -> classify -> attribute to enclosing
# method -> serialize. The static scan reports flag USAGE; it never claims staleness.
class TestFlags < Minitest::Test
  def setup
    root = fixture_path("flags")
    files = Dir.glob(File.join(root, "**", "*.rb")).sort
    @report = Moult::Flags.build_report(root: root, files: files)
    @by_key = @report.findings.to_h { |f| [f.flag_key, f] }
  end

  def test_catalogues_every_literal_flag_key
    assert_equal(
      %w[checkout_label discount_pct maintenance_mode new_checkout shipping_config verbose_shipping].sort,
      @by_key.keys.sort
    )
  end

  def test_value_types_are_classified_from_the_fetch_method
    assert_equal "boolean", @by_key["new_checkout"].value_type
    assert_equal "number", @by_key["discount_pct"].value_type
    assert_equal "string", @by_key["checkout_label"].value_type
    assert_equal "object", @by_key["shipping_config"].value_type
  end

  def test_a_multi_site_flag_groups_its_references
    flag = @by_key["new_checkout"]
    assert_equal 2, flag.reference_count
    assert_equal 2, flag.occurrences.size
  end

  def test_in_method_references_resolve_an_enclosing_symbol_id
    fqnames = @by_key["new_checkout"].occurrences.map(&:symbol_id)
    assert(fqnames.all? { |id| id&.include?("Billing#") }, "expected enclosing-method ids, got #{fqnames.inspect}")
  end

  def test_a_top_level_reference_resolves_to_a_null_symbol_id
    occ = @by_key["maintenance_mode"].occurrences.first
    assert_equal "top_level.rb", occ.path
    assert_nil occ.symbol_id
  end

  def test_occurrences_record_the_fetch_method_used
    assert_equal "fetch_boolean_details", @by_key["verbose_shipping"].occurrences.first.method_name
  end

  def test_literal_default_values_are_captured_and_non_literals_omitted
    assert_equal ["Pay"], @by_key["checkout_label"].default_values
    assert_equal ["false"], @by_key["new_checkout"].default_values
    assert_empty @by_key["shipping_config"].default_values
  end

  def test_dynamic_key_references_are_counted_not_catalogued
    assert_equal 1, @report.summary[:dynamic_references]
    refute @by_key.key?(nil)
  end

  def test_summary_aggregates_references_by_value_type
    summary = @report.summary
    assert_equal 6, summary[:flags]
    assert_equal 7, summary[:references]
    assert_equal 4, summary.dig(:by_value_type, "boolean")
    assert_equal 1, summary.dig(:by_value_type, "number")
  end

  def test_findings_are_sorted_most_referenced_first
    counts = @report.findings.map(&:reference_count)
    assert_equal counts.sort.reverse, counts
    assert_equal "new_checkout", @report.findings.first.flag_key
  end

  def test_every_finding_carries_a_null_confidence
    @report.findings.each { |f| assert_nil f.to_h[:confidence] }
  end

  def test_real_report_validates_against_the_schema
    schemer = schemer("flags.schema.json")
    data = JSON.parse(JSON.generate(@report.to_h))
    errors = schemer.validate(data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end

  def test_cli_runs_and_emits_valid_json
    out, = capture_io do
      status = Moult::CLI.new.run(["flags", fixture_path("flags"), "--format", "json", "--quiet"])
      assert_equal 0, status
    end
    data = JSON.parse(out)
    assert_equal "feature_flag", data.dig("findings", 0, "category")
    assert_empty schemer("flags.schema.json").validate(data).to_a
  end
end

# End-to-end with a merged provider snapshot: the static<->provider merge. Joins the
# scanned references to a flagd flag-definition export on the literal flag_key and
# grades each flag's staleness. The merge is evidence, never a claim of certain death.
class TestFlagsStalenessMerge < Minitest::Test
  def setup
    root = fixture_path("flags")
    files = Dir.glob(File.join(root, "**", "*.rb")).sort
    snapshot = Moult::Flags::Snapshot.load(fixture_path("flags", "provider", "flagd.json"))
    @report = Moult::Flags.build_report(root: root, files: files, snapshot: snapshot)
    @by_key = @report.findings.to_h { |f| [f.flag_key, f] }
  end

  def test_each_status_joins_on_the_literal_flag_key
    assert_equal "active", @by_key["new_checkout"].staleness.status       # enabled + targeting
    assert_equal "rolled_out", @by_key["discount_pct"].staleness.status   # enabled, no targeting
    assert_equal "disabled", @by_key["checkout_label"].staleness.status   # DISABLED
    assert_equal "archived", @by_key["shipping_config"].staleness.status  # metadata.archived
    assert_equal "archived", @by_key["verbose_shipping"].staleness.status # metadata.lifecycle
  end

  def test_a_code_key_unknown_to_the_provider_is_absent
    stale = @by_key["maintenance_mode"].staleness
    assert_equal "absent", stale.status
    # app.rb has a dynamic (non-literal) key, so the absent confidence is humbled.
    expected = Moult::Flags::Staleness::ABSENT_CONFIDENCE - Moult::Flags::Staleness::DYNAMIC_REFERENCE_PENALTY
    assert_in_delta expected, stale.confidence, 1e-9
  end

  def test_the_confidence_slot_is_populated_from_staleness
    @report.findings.each do |f|
      assert_equal f.staleness.confidence, f.to_h[:confidence]
    end
  end

  def test_findings_are_sorted_strongest_candidate_first
    confidences = @report.findings.map { |f| f.staleness.confidence }
    assert_equal confidences.sort.reverse, confidences
  end

  def test_summary_tallies_by_staleness_status
    tally = @report.summary[:by_staleness_status]
    assert_equal 2, tally["archived"]
    assert_equal 1, tally["absent"]
    assert_equal 1, tally["rolled_out"]
  end

  def test_report_is_schema_version_2_and_validates
    data = JSON.parse(JSON.generate(@report.to_h))
    assert_equal 2, data["schema_version"]
    assert_empty schemer("flags.schema.json").validate(data).to_a
  end

  def test_cli_with_provider_emits_graded_json
    out, = capture_io do
      status = Moult::CLI.new.run([
        "flags", fixture_path("flags"),
        "--provider", fixture_path("flags", "provider", "flagd.json"),
        "--format", "json", "--quiet"
      ])
      assert_equal 0, status
    end
    data = JSON.parse(out)
    assert_equal 2, data["schema_version"]
    assert_equal "flagd", data.dig("analysis", "provider", "backend")
    assert(data.fetch("findings").all? { |f| f.key?("staleness") })
    assert_empty schemer("flags.schema.json").validate(data).to_a
  end

  def test_cli_table_with_provider_shows_a_staleness_heading
    out, = capture_io do
      Moult::CLI.new.run([
        "flags", fixture_path("flags"),
        "--provider", fixture_path("flags", "provider", "flagd.json"),
        "--quiet"
      ])
    end
    assert_match(/staleness candidates \(confidence-graded, never certain\)/, out)
    assert_match(/STATUS/, out)
  end
end
