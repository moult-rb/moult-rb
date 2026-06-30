# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"

# Drives `moult gate` end to end through the CLI, pinning the distinct exit-code
# contract (0 pass / 1 gate-fail / 2 tool-error) and the format dispatch
# (table/json/github/sarif). The verdict logic itself is pinned in
# test_gate_policy.rb; this covers the CLI surface.
class TestGateCli < Minitest::Test
  def setup
    skip "rubydex unavailable" unless Moult::Index.available?
  end

  CLEAN = <<~RUBY
    class App
      def run
        1 + 1
      end
    end
  RUBY

  WITH_NEW_DEAD = <<~RUBY
    class App
      def run
        1 + 1
      end

      private

      def orphan
        99
      end
    end
  RUBY

  def test_clean_diff_passes_with_exit_zero
    committed_git_repo("app.rb" => CLEAN) do |root, base|
      out, _err, status = run_cli("gate", root, "--base", base, "--quiet")
      assert_equal 0, status
      assert_includes out, "moult gate: PASS"
    end
  end

  def test_violating_diff_fails_with_exit_one
    committed_git_repo("app.rb" => CLEAN) do |root, base|
      write_source(root, "app.rb", WITH_NEW_DEAD)
      out, _err, status = run_cli("gate", root, "--base", base, "--quiet")
      assert_equal 1, status, "a gate violation is exit 1, distinct from a tool error"
      assert_includes out, "moult gate: FAIL"
      assert_includes out, "no_new_dead_code"
    end
  end

  def test_unknown_path_is_tool_error_exit_two
    _out, err, status = run_cli("gate", "/no/such/dir", "--quiet")
    assert_equal 2, status, "a tool error is exit 2, distinct from a gate failure"
    assert_includes err, "no such file or directory"
  end

  def test_unresolvable_base_is_tool_error_exit_two
    committed_git_repo("app.rb" => CLEAN) do |root, _base|
      _out, err, status = run_cli("gate", root, "--base", "no/such/ref", "--quiet")
      assert_equal 2, status
      assert_includes err, "merge-base"
    end
  end

  def test_json_format_validates_against_the_contract
    committed_git_repo("app.rb" => CLEAN) do |root, base|
      write_source(root, "app.rb", WITH_NEW_DEAD)
      out, _err, status = run_cli("gate", root, "--base", base, "--format", "json", "--quiet")
      assert_equal 1, status
      data = JSON.parse(out)
      errors = schemer("gate.schema.json").validate(data).to_a
      assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
      assert_equal "fail", data["verdict"]
    end
  end

  def test_github_format_emits_error_annotations
    committed_git_repo("app.rb" => CLEAN) do |root, base|
      write_source(root, "app.rb", WITH_NEW_DEAD)
      out, _err, status = run_cli("gate", root, "--base", base, "--format", "github", "--quiet")
      assert_equal 1, status
      assert_match(/^::error file=app\.rb,line=\d+,title=Moult gate%3A no_new_dead_code::/, out)
    end
  end

  def test_sarif_format_is_valid_sarif_210
    committed_git_repo("app.rb" => CLEAN) do |root, base|
      write_source(root, "app.rb", WITH_NEW_DEAD)
      out, _err, status = run_cli("gate", root, "--base", base, "--format", "sarif", "--quiet")
      assert_equal 1, status
      doc = JSON.parse(out)
      assert_equal "2.1.0", doc["version"]
      assert_equal "moult", doc.dig("runs", 0, "tool", "driver", "name")
      assert_equal 4, doc.dig("runs", 0, "tool", "driver", "rules").size
      result = doc.dig("runs", 0, "results", 0)
      assert_equal "no_new_dead_code", result["ruleId"]
      assert_equal "error", result["level"]
      assert_equal "app.rb", result.dig("locations", 0, "physicalLocation", "artifactLocation", "uri")
    end
  end

  def test_config_file_can_relax_the_policy
    committed_git_repo("app.rb" => CLEAN) do |root, base|
      write_source(root, "app.rb", WITH_NEW_DEAD)
      write_source(root, ".moult.yml", "gate:\n  dead_code_max_confidence: 1.0\n")
      out, _err, status = run_cli("gate", root, "--base", base, "--format", "json", "--quiet")
      data = JSON.parse(out)
      assert_equal 0, status, "raising the dead-code bar to 1.0 lets the candidate through"
      assert_equal "pass", data["verdict"]
      assert_equal ".moult.yml", data.dig("policy", "source")
    end
  end

  def test_help_lists_the_gate_command
    out, _err, status = run_cli("--help")
    assert_equal 0, status
    assert_includes out, "gate"
  end

  private

  def run_cli(*argv)
    status = nil
    out, err = capture_io { status = Moult::CLI.start(argv) }
    [out, err, status]
  end
end
