# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"
require "tmpdir"
require "rbconfig"

# Drives `moult health` end to end through the CLI. Report-only: exit 0 on success
# (even on a low score — the PR gate is Phase 4), non-zero only on a hard error.
class TestHealthCli < Minitest::Test
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

  def with_project
    Dir.mktmpdir do |root|
      src = File.join(root, "thing.rb")
      cov = File.join(root, "coverage.json")
      File.write(src, SOURCE)
      script = <<~RB
        require "coverage"
        require "json"
        Coverage.start(lines: true)
        load #{src.inspect}
        File.write(#{cov.inspect}, JSON.generate(Coverage.result))
      RB
      flunk "failed to capture coverage" unless system(RbConfig.ruby, "-e", script)
      yield root, cov
    end
  end

  def run_cli(*argv)
    status = nil
    out, err = capture_io { status = Moult::CLI.start(argv) }
    [out, err, status]
  end

  def test_table_output_has_the_humble_heading_and_sections
    with_project do |root, _cov|
      out, _err, status = run_cli("health", root, "--quiet")
      assert_equal 0, status
      assert_includes out, "Codebase health:"
      assert_includes out, "not a verdict"
      assert_includes out, "Components:"
    end
  end

  def test_json_output_validates_and_carries_the_composite
    with_project do |root, _cov|
      out, _err, status = run_cli("health", root, "--format", "json", "--quiet")
      assert_equal 0, status
      data = JSON.parse(out)
      errors = schemer("health.schema.json").validate(data).to_a
      assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
      assert_equal 1, data["schema_version"]
      assert_includes %w[A B C D F], data.dig("overall", "grade")
    end
  end

  def test_coverage_flag_toggles_the_coverage_component
    with_project do |root, cov|
      without = component(run_health_json(root), "coverage")
      refute without["present"], "coverage component is skipped without --coverage"
      assert_equal "no --coverage supplied", without["diagnostic"]

      with = component(run_health_json(root, "--coverage", cov), "coverage")
      assert with["present"], "coverage component contributes with --coverage"
      assert_kind_of Numeric, with["score"]
    end
  end

  def test_exit_zero_even_when_health_is_low
    with_project do |root, _cov|
      _out, _err, status = run_cli("health", root, "--format", "json", "--quiet")
      assert_equal 0, status, "report-only: a low score is not a failure exit"
    end
  end

  def test_unknown_path_is_a_hard_error
    _out, err, status = run_cli("health", "/no/such/dir", "--quiet")
    assert_equal 1, status
    assert_includes err, "no such file or directory"
  end

  def test_help_lists_the_health_command
    out, _err, status = run_cli("--help")
    assert_equal 0, status
    assert_includes out, "health"
  end

  private

  def run_health_json(root, *extra)
    out, _err, status = run_cli("health", root, "--format", "json", "--quiet", *extra)
    assert_equal 0, status
    JSON.parse(out)
  end

  def component(data, name)
    data.fetch("components").find { |c| c["name"] == name }
  end
end
