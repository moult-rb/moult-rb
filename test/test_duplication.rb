# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# End-to-end over real fixture files containing deliberate IDENTICAL duplication
# (deterministic; fuzzy off). Drives the library directly rather than through
# Discovery so it does not depend on the fixtures being git-tracked.
class TestDuplication < Minitest::Test
  def build(min_mass: 8)
    root = fixture_path("duplication")
    files = Dir[File.join(root, "*.rb")].sort
    Moult::Duplication.build_report(root: root, files: files, min_mass: min_mass)
  end

  def test_finds_the_identical_method_clone_attributed_to_its_methods
    finding = build.findings.find { |f| f.node_type == "defn" }
    refute_nil finding, "expected the duplicated #normalize method to be found"
    assert_equal :identical, finding.kind
    symbols = finding.occurrences.map(&:symbol_id).sort
    assert_equal ["alpha.rb:12:Alpha#normalize", "beta.rb:4:Beta#normalize"], symbols
  end

  def test_top_level_clone_resolves_to_a_null_symbol_id
    null_occurrences = build.findings.flat_map(&:occurrences).select { |o| o.symbol_id.nil? }
    refute_empty null_occurrences, "the top-level constant clone should not attribute to a method"
    assert(null_occurrences.all? { |o| %w[config_a.rb config_b.rb].include?(o.path) })
  end

  def test_confidence_matches_the_pinned_model
    finding = build.findings.find { |f| f.node_type == "defn" }
    # identical (0.60) + medium mass (0.10) + whole defn (0.08) = 0.78
    assert_in_delta 0.78, finding.confidence, 0.001
  end

  def test_every_finding_has_at_least_two_occurrences
    build.findings.each { |f| assert_operator f.occurrences.size, :>=, 2 }
  end

  def test_a_high_min_mass_filters_out_the_small_clones
    assert_empty build(min_mass: 10_000).findings
  end

  def test_real_report_validates_against_the_schema
    schemer = schemer("duplication.schema.json")
    data = JSON.parse(JSON.generate(build.to_h))
    errors = schemer.validate(data).to_a
    assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
  end
end
