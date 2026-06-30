# frozen_string_literal: true

require "test_helper"

# The line->symbol resolver is "the one genuinely novel component", so it gets
# the same drift-is-a-bug treatment as the ABC metric: every classification rule
# is pinned against a hand-built line array and span. Line arrays are 0-indexed
# (index 0 = line 1); nil = non-executable, 0 = executable-not-run, N = hits.
class TestCoverageResolver < Minitest::Test
  R = Moult::Coverage::Resolver

  def dataset(entries)
    Moult::Coverage::Dataset.new(entries: entries, source: nil, unmatched_count: 0)
  end

  def span(start_line, end_line)
    Moult::Span.new(start_line: start_line, start_column: 0, end_line: end_line, end_column: 3)
  end

  def classify(lines, span, kind: :method, path: "f.rb")
    R.classify(dataset({path => lines}), path: path, span: span, kind: kind)
  end

  # ---- the crux: the def line is counted at load time, never per-call --------

  def test_def_line_hit_but_body_unrun_is_cold
    # line 2 is `def` (counted at load = 1); body lines 3-4 are 0.
    assert_equal :cold, classify([nil, 1, 0, 0, nil], span(2, 5))
  end

  def test_def_line_excluded_body_executed_is_hot
    assert_equal :hot, classify([nil, 1, 5, 0, nil], span(2, 5))
  end

  # ---- hot / cold basics ----------------------------------------------------

  def test_any_executed_body_line_is_hot
    assert_equal :hot, classify([nil, 1, 0, 3, nil], span(2, 5))
  end

  def test_all_zero_body_is_cold
    assert_equal :cold, classify([nil, 1, 0, 0, 0], span(2, 5))
  end

  # ---- nil vs 0 discrimination ----------------------------------------------

  def test_nil_lines_skipped_zero_counts_cold
    # body lines: line3 nil (non-executable, skipped), line4 0 (executable) => cold
    assert_equal :cold, classify([nil, 1, nil, 0], span(2, 4))
  end

  def test_nil_lines_skipped_positive_counts_hot
    assert_equal :hot, classify([nil, 1, nil, 2], span(2, 4))
  end

  # ---- untracked: no usable signal ------------------------------------------

  def test_one_line_method_is_untracked
    # span start == end: the only line is the def line, excluded -> empty body.
    assert_equal :untracked, classify([nil, nil, 1], span(3, 3))
  end

  def test_body_with_only_nonexecutable_lines_is_untracked
    # def + end, no executable body line.
    assert_equal :untracked, classify([nil, 1, nil], span(2, 3))
  end

  def test_file_absent_from_dataset_is_untracked
    ds = dataset({"other.rb" => [nil, 1, 1]})
    assert_equal :untracked, R.classify(ds, path: "missing.rb", span: span(2, 3), kind: :method)
  end

  def test_constant_is_always_untracked
    # Even with a hit, a constant's line runs at load -> no runtime signal.
    assert_equal :untracked, classify([nil, 1, 1], span(2, 3), kind: :constant)
  end

  # ---- robustness -----------------------------------------------------------

  def test_span_extending_past_array_end_uses_available_lines
    # array stops at line 3; lines 4-6 are treated as nil (skipped).
    assert_equal :hot, classify([nil, 1, 4], span(2, 6))
  end

  def test_empty_line_array_is_untracked
    assert_equal :untracked, classify([], span(2, 3))
  end
end
