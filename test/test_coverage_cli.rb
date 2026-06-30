# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"
require "tmpdir"
require "rbconfig"

# Drives `moult coverage` and `moult deadcode --coverage` end to end through the
# real rubydex index and a REAL stdlib Coverage capture (run in a subprocess so
# the test process stays clean). This also exercises the realpath path-join
# between coverage keys and the symbol_id paths Phase 2 emits.
class TestCoverageCli < Minitest::Test
  def setup
    skip "rubydex unavailable" unless Moult::Index.available?
  end

  SOURCE = <<~RUBY
    module Lib
      class Thing
        def used
          helper
        end

        private

        def helper
          1
        end

        def dead_one
          2
        end
      end
    end

    Lib::Thing.new.used
  RUBY

  # Build a temp project and capture genuine line coverage for it. `used` and
  # `helper` execute (hot); `dead_one` is defined but never called (cold).
  def with_covered_project
    Dir.mktmpdir do |root|
      src = File.join(root, "thing.rb")
      cov = File.join(root, "coverage.json")
      File.write(src, SOURCE)
      capture_coverage(src, cov)
      yield root, cov
    end
  end

  def capture_coverage(src, cov)
    script = <<~RB
      require "coverage"
      require "json"
      Coverage.start(lines: true)
      load #{src.inspect}
      File.write(#{cov.inspect}, JSON.generate(Coverage.result))
    RB
    ok = system(RbConfig.ruby, "-e", script)
    flunk "failed to capture coverage" unless ok
  end

  def run_cli(*argv)
    status = nil
    out, err = capture_io { status = Moult::CLI.start(argv) }
    [out, err, status]
  end

  # ---- moult coverage -------------------------------------------------------

  def test_coverage_map_classifies_hot_and_cold
    with_covered_project do |root, cov|
      out, _err, status = run_cli("coverage", root, "--coverage", cov, "--format", "json", "--quiet")
      assert_equal 0, status
      data = JSON.parse(out)
      errors = schemer("coverage.schema.json").validate(data).to_a
      assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"

      runtime = data.fetch("symbols").to_h { |s| [s["name"], s["runtime"]] }
      assert_equal "hot", runtime["Lib::Thing#used"]
      assert_equal "hot", runtime["Lib::Thing#helper"]
      assert_equal "cold", runtime["Lib::Thing#dead_one"]
      assert_operator data.dig("summary", "hot"), :>=, 2
      assert_operator data.dig("summary", "cold"), :>=, 1
    end
  end

  def test_coverage_table_has_summary_heading
    with_covered_project do |root, cov|
      out, _err, status = run_cli("coverage", root, "--coverage", cov, "--quiet")
      assert_equal 0, status
      assert_includes out, "Runtime coverage map:"
      assert_includes out, "dead_one"
    end
  end

  def test_coverage_requires_the_flag
    with_covered_project do |root, _cov|
      _out, err, status = run_cli("coverage", root, "--quiet")
      assert_equal 1, status
      assert_includes err, "requires --coverage"
    end
  end

  # ---- moult deadcode --coverage (the merge) --------------------------------

  def test_deadcode_merge_validates_v2_and_marks_cold_candidate
    with_covered_project do |root, cov|
      out, _err, status = run_cli("deadcode", root, "--coverage", cov, "--format", "json", "--quiet")
      assert_equal 0, status
      data = JSON.parse(out)
      assert_equal 2, data["schema_version"]
      errors = schemer("deadcode.schema.json").validate(data).to_a
      assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
      assert_equal "coverage", data.dig("analysis", "coverage", "backend")

      dead = data.fetch("findings").find { |f| f["name"] == "Lib::Thing#dead_one" }
      refute_nil dead, "an unreferenced, never-executed method is a strong candidate"
      assert_equal "cold", dead["runtime"]
      assert(dead["reasons"].any? { |r| r["rule"] == "runtime_cold" })
    end
  end

  def test_deadcode_table_shows_runtime_column_with_coverage
    with_covered_project do |root, cov|
      out, _err, status = run_cli("deadcode", root, "--coverage", cov, "--quiet")
      assert_equal 0, status
      assert_includes out, "RUNTIME"
    end
  end

  def test_help_lists_coverage_command
    out, _err, status = run_cli("--help")
    assert_equal 0, status
    assert_includes out, "coverage"
  end
end
