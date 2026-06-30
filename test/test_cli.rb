# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "json_schemer"

class TestCLI < Minitest::Test
  def test_version_flag
    out, _err, status = run_cli(["--version"])
    assert_equal 0, status
    assert_equal Moult::VERSION, out.strip
  end

  def test_help_with_no_args
    out, _err, status = run_cli([])
    assert_equal 0, status
    assert_includes out, "moult hotspots"
  end

  def test_unknown_command_errors
    _out, err, status = run_cli(["frobnicate"])
    assert_equal 1, status
    assert_includes err, "unknown command"
  end

  def test_hotspots_table_on_a_directory
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "def f; if a; b; end; end")
      out, _err, status = run_cli(["hotspots", dir, "--quiet"])
      assert_equal 0, status
      assert_includes out, "a.rb"
      assert_includes out, "SCORE"
    end
  end

  def test_hotspots_json_validates_against_contract
    validator = schemer("hotspots.schema.json")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "class C\n  def f; foo(bar); end\nend\n")
      out, _err, status = run_cli(["hotspots", dir, "--format", "json", "--quiet"])
      assert_equal 0, status
      data = JSON.parse(out)
      assert_empty validator.validate(data).to_a
      assert_equal "a.rb", data.dig("hotspots", 0, "path")
    end
  end

  def test_invalid_format_errors
    _out, err, status = run_cli(["hotspots", ".", "--format", "yaml", "--quiet"])
    assert_equal 1, status
    refute_empty err
  end

  def test_missing_path_errors
    _out, err, status = run_cli(["hotspots", "/no/such/path/here", "--quiet"])
    assert_equal 1, status
    assert_includes err, "no such file"
  end

  private

  def run_cli(argv)
    status = nil
    out, err = capture_io { status = Moult::CLI.new.run(argv) }
    [out, err, status]
  end
end
