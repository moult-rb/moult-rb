# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "time"

# Pins the coverage ingestion adapters: format auto-detection, the SimpleCov and
# stdlib-Coverage shapes, multi-command merging, path relativization onto the
# analysis root (with out-of-root files counted), and provenance capture.
#
# Fixtures use synthetic "/project" paths; the loader's canonicalize falls back
# to expand_path for paths that don't exist locally, so relativizing against
# root "/project" is deterministic on any machine.
class TestCoverageLoader < Minitest::Test
  ROOT = "/project"

  def load(name, **opts)
    Moult::Coverage.load(fixture_path("coverage", name), root: ROOT, **opts)
  end

  # ---- auto-detection -------------------------------------------------------

  def test_detects_simplecov_by_coverage_key
    ds = load("simplecov.resultset.json")
    assert_equal "simplecov", ds.source.backend
  end

  def test_detects_stdlib_coverage_wrapped_and_bare
    assert_equal "coverage", load("coverage.lines.json").source.backend
    assert_equal "coverage", load("coverage.bare.json").source.backend
  end

  def test_explicit_format_overrides_detection
    ds = load("coverage.bare.json", format: :coverage)
    assert ds.tracked?("lib/a.rb")
  end

  # ---- SimpleCov adapter ----------------------------------------------------

  def test_simplecov_relativizes_paths_and_counts_out_of_root
    ds = load("simplecov.resultset.json")
    assert_equal [1, 1, 0, nil], ds.entries["lib/a.rb"]
    assert_equal [nil, 1, 1], ds.entries["lib/b.rb"]
    refute ds.tracked?("vendor/c.rb"), "files outside root are dropped"
    assert_equal 1, ds.unmatched_count
  end

  def test_simplecov_collected_at_from_timestamp
    ds = load("simplecov.resultset.json")
    assert_equal Time.at(1750000000).utc.iso8601, ds.source.collected_at
    assert_nil ds.source.version
  end

  def test_simplecov_merges_commands_elementwise
    ds = load("simplecov.multi.json")
    # [1,0,nil,0] merged with [0,1,nil,nil] -> [1,1,nil,0]
    assert_equal [1, 1, nil, 0], ds.entries["lib/a.rb"]
    # latest timestamp wins
    assert_equal Time.at(1750000500).utc.iso8601, ds.source.collected_at
  end

  # ---- stdlib Coverage adapter ----------------------------------------------

  def test_coverage_wrapped_extracts_lines_ignoring_methods_branches
    ds = load("coverage.lines.json")
    assert_equal [1, 1, 0, nil], ds.entries["lib/a.rb"]
    assert_equal [nil, 0], ds.entries["lib/b.rb"]
  end

  def test_coverage_bare_array_form
    ds = load("coverage.bare.json")
    assert_equal [1, 1, 0, nil], ds.entries["lib/a.rb"]
  end

  def test_coverage_version_is_ruby_version
    assert_equal RUBY_VERSION, load("coverage.bare.json").source.version
  end

  def test_coverage_collected_at_falls_back_to_file_mtime
    ds = load("coverage.bare.json")
    expected = File.mtime(fixture_path("coverage", "coverage.bare.json")).utc.iso8601
    assert_equal expected, ds.source.collected_at
  end

  # ---- dataset accessors ----------------------------------------------------

  def test_line_value_is_one_based
    ds = load("coverage.bare.json")
    assert_equal 1, ds.line_value("lib/a.rb", 1)
    assert_equal 0, ds.line_value("lib/a.rb", 3)
    assert_nil ds.line_value("lib/a.rb", 4)
    assert_nil ds.line_value("missing.rb", 1)
  end

  # ---- errors ---------------------------------------------------------------

  def test_missing_file_raises_moult_error
    err = assert_raises(Moult::Error) { Moult::Coverage.load("/no/such/cov.json", root: ROOT) }
    assert_includes err.message, "no such coverage file"
  end

  def test_malformed_json_raises_moult_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.json")
      File.write(path, "{not json")
      err = assert_raises(Moult::Error) { Moult::Coverage.load(path, root: ROOT) }
      assert_includes err.message, "could not parse"
    end
  end

  def test_undetectable_format_raises
    Dir.mktmpdir do |dir|
      path = File.join(dir, "weird.json")
      File.write(path, JSON.generate({"k" => "v"}))
      err = assert_raises(Moult::Error) { Moult::Coverage.load(path, root: ROOT) }
      assert_includes err.message, "auto-detect"
    end
  end
end
