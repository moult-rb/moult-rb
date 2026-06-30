# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestScoring < Minitest::Test
  def test_combine_is_complexity_times_churn
    assert_equal 30, Moult::Scoring.combine(10, 3)
    assert_in_delta 6.4, Moult::Scoring.combine(3.2, 2), 0.001
    assert_equal 0, Moult::Scoring.combine(99.0, 0)
  end

  def test_build_report_ranks_by_score_descending
    Dir.mktmpdir do |dir|
      # complexity 3.2, churn 2 => score 6.4
      write(dir, "branchy.rb", "def f; if a; b; end; end")
      # complexity 1.0, churn 5 => score 5.0
      write(dir, "trivial.rb", "def g; x = 1; end")

      report = build(dir, churn: {"branchy.rb" => 2, "trivial.rb" => 5})

      assert_equal ["branchy.rb", "trivial.rb"], report.hotspots.map(&:path)
      assert_in_delta 6.4, report.hotspots[0].score, 0.001
      assert_in_delta 5.0, report.hotspots[1].score, 0.001
      assert_in_delta 3.2, report.hotspots[0].complexity, 0.001
      assert_equal 2, report.hotspots[0].churn
    end
  end

  def test_files_without_methods_are_omitted
    Dir.mktmpdir do |dir|
      write(dir, "blank.rb", "# just a comment\nCONST = 1\n")
      write(dir, "real.rb", "def g; x = 1; end")

      report = build(dir, churn: {"real.rb" => 1})

      assert_equal ["real.rb"], report.hotspots.map(&:path)
    end
  end

  def test_keeps_only_worst_methods_for_drilldown
    Dir.mktmpdir do |dir|
      write(dir, "many.rb", <<~RUBY)
        class C
          def a; if x; y; end; end
          def b; z = 1; end
          def c; foo(bar); end
          def d; end
        end
      RUBY

      report = build(dir, churn: {"many.rb" => 1}, worst_methods: 2)
      hotspot = report.hotspots.first

      assert_equal 2, hotspot.methods.size
      # methods are ordered worst-first
      abcs = hotspot.methods.map(&:abc)
      assert_equal abcs.sort.reverse, abcs
      assert_equal "C#a", hotspot.worst_method.name
    end
  end

  def test_method_symbol_id_encodes_path_line_and_name
    Dir.mktmpdir do |dir|
      write(dir, "lib/foo.rb", "class Foo\n  def bar; baz; end\nend\n")
      report = build(dir, churn: {"lib/foo.rb" => 1})
      method = report.hotspots.first.methods.first

      assert_equal "lib/foo.rb:2:Foo#bar", method.symbol_id
    end
  end

  def test_zero_churn_files_still_order_by_complexity
    Dir.mktmpdir do |dir|
      write(dir, "big.rb", "def f; if a; if b; c; end; end; end")
      write(dir, "small.rb", "def g; x = 1; end")

      # empty churn map => all churn 0 (e.g. outside a repo)
      report = build(dir, churn: Hash.new(0))

      assert_equal ["big.rb", "small.rb"], report.hotspots.map(&:path)
      assert(report.hotspots.all? { |h| h.score.zero? })
    end
  end

  private

  def write(dir, rel, contents)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  def build(dir, churn:, worst_methods: Moult::Scoring::DEFAULT_WORST_METHODS)
    files = Dir.glob(File.join(dir, "**", "*.rb"))
    Moult::Scoring.build_report(root: dir, files: files, churn: churn, worst_methods: worst_methods)
  end
end
