# frozen_string_literal: true

# test/test_cloud_upload.rb
require "test_helper"

class TestCloudUpload < Minitest::Test
  def report
    {
      "schema_version" => 1,
      "tool" => {"name" => "moult", "version" => "0.1.0"},
      "analysis" => {"root" => "/Users/alice/secret-project", "git_ref" => "HEAD",
                     "generated_at" => nil, "base_ref" => "origin/main", "merge_base" => "abc",
                     "scope" => "diff", "components" => []},
      "policy" => {"source" => "default"},
      "verdict" => "fail",
      "reasons" => [{"rule" => "dead_code", "detail" => "1 new candidate"}],
      "summary" => {"rules" => 4, "evaluated" => 4, "failed" => 1, "findings" => 1},
      "rules" => [],
      "leaked_future_key" => "must not be uploaded"
    }
  end

  def test_strips_absolute_root_path
    out = Moult::CloudUpload.projection(report)
    assert_equal ".", out["analysis"]["root"], "absolute local path must be normalised away"
  end

  def test_preserves_non_leaky_analysis_fields
    out = Moult::CloudUpload.projection(report)
    assert_equal "diff", out["analysis"]["scope"]
    assert_equal "origin/main", out["analysis"]["base_ref"]
  end

  def test_drops_unknown_top_level_keys
    out = Moult::CloudUpload.projection(report)
    refute out.key?("leaked_future_key"), "unknown top-level keys must be dropped"
  end

  def test_preserves_verdict_and_rules_envelope
    out = Moult::CloudUpload.projection(report)
    assert_equal "fail", out["verdict"]
    assert_equal 1, out["summary"]["failed"]
    assert_equal [], out["rules"]
  end

  def test_does_not_mutate_input
    original = report
    Moult::CloudUpload.projection(original)
    assert_equal "/Users/alice/secret-project", original["analysis"]["root"], "input must not be mutated"
  end
end
