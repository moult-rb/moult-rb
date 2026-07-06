# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"
require "tmpdir"

# Drives `moult cycles` end to end through the real rubydex-backed index.
# Skips when the native gem is unavailable so the rest of the suite still runs.
class TestCyclesCli < Minitest::Test
  def setup
    skip "rubydex unavailable" unless Moult::Index.available?
  end

  def with_cyclic_project
    Dir.mktmpdir do |root|
      File.write(File.join(root, "a.rb"), "class A\n  def touch = B\nend\n")
      File.write(File.join(root, "b.rb"), "class B\n  def touch = A\nend\n")
      File.write(File.join(root, "c.rb"), "class C\nend\n")
      yield root
    end
  end

  def run_cli(*argv)
    status = nil
    out, err = capture_io { status = Moult::CLI.start(argv) }
    [out, err, status]
  end

  def test_table_lists_cycle_files_only
    with_cyclic_project do |root|
      out, _err, status = run_cli("cycles", root, "--quiet")
      assert_equal 0, status
      assert_includes out, "a.rb -> b.rb -> a.rb"
      refute_includes out, "c.rb"
    end
  end

  def test_json_validates_against_contract
    with_cyclic_project do |root|
      out, _err, status = run_cli("cycles", root, "--format", "json", "--quiet")
      assert_equal 0, status
      data = JSON.parse(out)
      assert_empty schemer("cycles.schema.json").validate(data).to_a
      assert_equal 1, data.dig("summary", "cycles")
      assert_equal %w[a.rb b.rb], data["findings"][0]["files"]
    end
  end

  def test_acyclic_project_reports_none
    Dir.mktmpdir do |root|
      File.write(File.join(root, "c.rb"), "class C\nend\n")
      out, _err, status = run_cli("cycles", root, "--quiet")
      assert_equal 0, status
      assert_includes out, "No cycles found."
    end
  end

  def test_missing_path_errors
    _out, err, status = run_cli("cycles", "/nope/missing")
    assert_equal 1, status
    assert_match(/no such file/, err)
  end
end
