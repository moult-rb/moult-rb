# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestChurn < Minitest::Test
  def test_parse_counts_commits_per_file
    counts = Moult::Churn.parse(fixture("churn", "git_log.txt"))
    assert_equal 3, counts["lib/a.rb"]
    assert_equal 1, counts["lib/b.rb"]
    assert_equal 1, counts["lib/c.rb"]
  end

  def test_parse_ignores_blank_commit_separators
    counts = Moult::Churn.parse(fixture("churn", "git_log.txt"))
    refute counts.key?("")
    assert_equal 3, counts.size
  end

  def test_parse_returns_zero_for_unknown_files
    counts = Moult::Churn.parse(fixture("churn", "git_log.txt"))
    assert_equal 0, counts["lib/never_touched.rb"]
  end

  def test_parse_handles_empty_output
    assert_empty Moult::Churn.parse("")
  end

  def test_collect_outside_a_repo_yields_empty_churn
    Dir.mktmpdir do |dir|
      counts = Moult::Churn.collect(root: dir)
      assert_empty counts
      assert_equal 0, counts["anything.rb"]
    end
  end
end
