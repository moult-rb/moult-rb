# frozen_string_literal: true

require_relative "test_helper"

# Pins the diff parser and filter against hand-built git output. This is the
# genuinely novel component of the gate — the line→diff intersection — so it is
# pinned like the coverage resolver and ABC; drift is a bug. {Diff.parse} is pure,
# so these need no git repo (the end-to-end merge-base path is covered by test_gate.rb).
class TestDiff < Minitest::Test
  D = Moult::Diff

  # A representative `git diff --unified=0` over one modified file with two hunks,
  # one added file, and one deleted file.
  UNIFIED = <<~DIFF
    diff --git a/lib/a.rb b/lib/a.rb
    index 1111111..2222222 100644
    --- a/lib/a.rb
    +++ b/lib/a.rb
    @@ -4,0 +5,2 @@ class A
    +  def added
    +  end
    @@ -20 +22,3 @@ def tail
    +  one
    +  two
    +  three
    diff --git a/lib/new.rb b/lib/new.rb
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/lib/new.rb
    @@ -0,0 +1,3 @@
    +class New
    +  X = 1
    +end
    diff --git a/lib/gone.rb b/lib/gone.rb
    deleted file mode 100644
    index 4444444..0000000
    --- a/lib/gone.rb
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -class Gone
    -end
  DIFF

  NAME_STATUS = <<~STATUS
    M\tlib/a.rb
    A\tlib/new.rb
    D\tlib/gone.rb
  STATUS

  def diff(scope: :diff)
    D.parse(name_status: NAME_STATUS, unified_diff: UNIFIED, base_ref: "origin/main", merge_base: "abc1234", scope: scope)
  end

  # ---- parsing is pinned -----------------------------------------------------

  def test_parses_every_changed_file_with_its_status
    statuses = diff.files.to_h { |f| [f.path, f.status] }
    assert_equal({"lib/a.rb" => "M", "lib/new.rb" => "A", "lib/gone.rb" => "D"}, statuses)
  end

  def test_recovers_new_side_line_ranges_from_hunk_headers
    a = diff.files.find { |f| f.path == "lib/a.rb" }
    # "@@ -4,0 +5,2 @@" -> 5..6 ; "@@ -20 +22,3 @@" -> 22..24
    assert_equal [(5..6), (22..24)], a.line_ranges
  end

  def test_added_file_carries_its_full_new_range
    n = diff.files.find { |f| f.path == "lib/new.rb" }
    assert_equal [(1..3)], n.line_ranges
  end

  def test_deleted_file_has_no_new_lines
    g = diff.files.find { |f| f.path == "lib/gone.rb" }
    assert_empty g.line_ranges
  end

  def test_single_line_hunk_defaults_count_to_one
    # "@@ -20 +22,3 @@" was a count -> covered above; assert the no-comma +N form:
    one = D.parse(name_status: "M\tx.rb\n", unified_diff: "+++ b/x.rb\n@@ -7 +7 @@\n+changed\n", base_ref: "b", merge_base: "m")
    assert_equal [(7..7)], one.files.first.line_ranges
  end

  def test_carries_base_ref_merge_base_and_scope
    d = diff
    assert_equal "origin/main", d.base_ref
    assert_equal "abc1234", d.merge_base
    assert_equal :diff, d.scope
  end

  # ---- the filter is pinned --------------------------------------------------

  def test_in_diff_true_when_span_overlaps_a_changed_range
    assert diff.in_diff?(path: "lib/a.rb", start_line: 5, end_line: 6)
    assert diff.in_diff?(path: "lib/a.rb", start_line: 1, end_line: 5), "straddling start counts"
    assert diff.in_diff?(path: "lib/a.rb", start_line: 24, end_line: 30), "straddling end counts"
  end

  def test_in_diff_false_when_span_misses_every_changed_range
    refute diff.in_diff?(path: "lib/a.rb", start_line: 8, end_line: 21)
  end

  def test_in_diff_false_for_unchanged_file
    refute diff.in_diff?(path: "lib/untouched.rb", start_line: 1, end_line: 100)
  end

  def test_line_level_finding_on_a_deletion_only_file_does_not_match
    # gone.rb changed but has no new lines; a line-keyed finding must not trip.
    refute diff.in_diff?(path: "lib/gone.rb", start_line: 1, end_line: 2)
  end

  def test_includes_path_is_the_path_level_fallback
    assert diff.includes_path?("lib/gone.rb"), "deleted file still counts as a changed path"
    assert diff.includes_path?("lib/a.rb")
    refute diff.includes_path?("lib/untouched.rb")
  end

  def test_nil_start_line_falls_back_to_path_level
    assert diff.in_diff?(path: "lib/gone.rb")
    refute diff.in_diff?(path: "lib/untouched.rb")
  end

  # ---- scope :all ------------------------------------------------------------

  def test_scope_all_includes_everything
    all = diff(scope: :all)
    assert all.in_diff?(path: "anything.rb", start_line: 999, end_line: 1000)
    assert all.includes_path?("anything.rb")
  end

  def test_compute_all_scope_needs_no_git
    d = D.compute(root: "/nonexistent", base_ref: "origin/main", scope: :all)
    assert_equal :all, d.scope
    assert_nil d.merge_base
    assert d.includes_path?("whatever.rb")
  end

  # ---- encoding robustness ---------------------------------------------------

  # git emits UTF-8; under a non-UTF-8 locale Open3 tags its output with the
  # ASCII default external encoding, so naive string ops would raise on the high
  # bytes of an added line (e.g. an em-dash in a comment). The parser must cope.
  def test_parses_diff_text_with_non_ascii_bytes_tagged_ascii
    unified = (+"+++ b/lib/a.rb\n@@ -0,0 +1 @@\n+# costs €5 — cheap\n").force_encoding("US-ASCII")
    name_status = (+"M\tlib/a.rb\n").force_encoding("US-ASCII")
    d = D.parse(name_status: name_status, unified_diff: unified, base_ref: "b", merge_base: "m")
    assert_equal [(1..1)], d.files.first.line_ranges
  end

  # ---- rename resolves to the new path --------------------------------------

  def test_rename_status_resolves_to_new_path
    d = D.parse(name_status: "R100\tlib/old.rb\tlib/new_name.rb\n", unified_diff: "", base_ref: "b", merge_base: "m")
    assert_equal ["lib/new_name.rb"], d.files.map(&:path)
    assert_equal "R", d.files.first.status
  end
end
