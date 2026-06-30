# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"
require "tmpdir"

# Drives `moult deadcode` end to end through the real rubydex-backed index.
# Skips when the native gem is unavailable so the rest of the suite still runs.
class TestDeadCodeCli < Minitest::Test
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
      File.write(File.join(root, "thing.rb"), SOURCE)
      yield root
    end
  end

  def run_cli(*argv)
    status = nil
    out, err = capture_io { status = Moult::CLI.start(argv) }
    [out, err, status]
  end

  def test_table_output_lists_dead_candidate_with_caveat
    with_project do |root|
      out, _err, status = run_cli("deadcode", root, "--quiet")
      assert_equal 0, status
      assert_includes out, "not certainties"
      assert_includes out, "Lib::Thing#dead_one"
    end
  end

  def test_json_output_validates_against_schema
    with_project do |root|
      out, _err, status = run_cli("deadcode", root, "--format", "json", "--quiet")
      assert_equal 0, status
      data = JSON.parse(out)
      errors = schemer("deadcode.schema.json").validate(data).to_a
      assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
      names = data.fetch("findings").map { |f| f["name"] }
      assert_includes names, "Lib::Thing#dead_one"
      refute_includes names, "Lib::Thing#used", "a referenced method is not dead"
    end
  end

  def test_min_confidence_filters_findings
    with_project do |root|
      out, _err, status = run_cli("deadcode", root, "--format", "json", "--quiet", "--min-confidence", "0.99")
      assert_equal 0, status
      assert_empty JSON.parse(out).fetch("findings")
    end
  end

  def test_nonexistent_path_errors
    _out, err, status = run_cli("deadcode", "/no/such/path/xyz")
    assert_equal 1, status
    assert_includes err, "no such file or directory"
  end

  def test_invalid_format_errors
    with_project do |root|
      _out, err, status = run_cli("deadcode", root, "--format", "yaml", "--quiet")
      assert_equal 1, status
      assert_includes err, "moult:"
    end
  end

  def test_help_lists_deadcode_command
    out, _err, status = run_cli("--help")
    assert_equal 0, status
    assert_includes out, "deadcode"
  end
end
