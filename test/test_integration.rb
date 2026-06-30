# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# End-to-end: build a real git repository with controlled churn, run the CLI
# against it, and assert that churn actually moves the ranking and that JSON
# output honours the contract.
class TestIntegration < Minitest::Test
  # A low-complexity file edited often must outrank a complex file edited once,
  # because score = complexity x churn.
  def test_churn_reorders_against_complexity
    in_git_repo do |dir|
      # complexity ~5.62, one method, committed once
      write_source(dir, "complex_but_stable.rb", "def f; if a; if b; c; end; end; end")
      # complexity 1.0, but edited many times
      write_source(dir, "simple_but_churny.rb", "def g; x = 1; end")
      git_commit(dir, "initial")

      6.times do |i|
        append(dir, "simple_but_churny.rb", "# touch #{i}\n")
        git_commit(dir, "edit #{i}")
      end

      report = run_json(dir)
      paths = report["hotspots"].map { |h| h["path"] }

      assert_equal ["simple_but_churny.rb", "complex_but_stable.rb"], paths
      churny, complex = report["hotspots"]
      assert_equal 7, churny["churn"]
      assert_operator churny["score"], :>, complex["score"]
      assert_operator complex["complexity"], :>, churny["complexity"]
    end
  end

  def test_json_output_validates_against_contract
    validator = schemer("hotspots.schema.json")
    in_git_repo do |dir|
      write_source(dir, "lib/widget.rb", "class Widget\n  def build; assemble(parts); end\nend\n")
      git_commit(dir, "add widget")

      report = run_json(dir)
      assert_empty validator.validate(report).to_a
      assert_equal 40, report.dig("analysis", "git_ref").length # full sha
      assert_equal "lib/widget.rb:2:Widget#build", report.dig("hotspots", 0, "methods", 0, "symbol_id")
    end
  end

  def test_table_output_against_a_repo
    in_git_repo do |dir|
      write_source(dir, "a.rb", "def f; if a; b; end; end")
      git_commit(dir, "add a")
      out, status = run_cli(dir, "--format", "table")
      assert_equal 0, status
      assert_includes out, "a.rb"
      assert_includes out, "churn over last 12 months"
    end
  end

  def test_executable_reports_version
    out, _err, status = Open3.capture3("bundle", "exec", "exe/moult", "--version", chdir: project_root)
    assert status.success?
    assert_equal Moult::VERSION, out.strip
  end

  private

  def project_root
    File.expand_path("..", __dir__)
  end

  def run_cli(dir, *args)
    status = nil
    out, = capture_io { status = Moult::CLI.new.run(["hotspots", dir, "--quiet", *args]) }
    [out, status]
  end

  def run_json(dir)
    out, status = run_cli(dir, "--format", "json")
    assert_equal 0, status
    JSON.parse(out)
  end

  def append(dir, rel, contents)
    File.write(File.join(dir, rel), contents, mode: "a")
  end
end
