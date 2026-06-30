# frozen_string_literal: true

require "test_helper"
require "json"
require "json_schemer"
require "tmpdir"
require "rbconfig"

# Drives the health orchestration end to end over a real temp project (real
# rubydex index, real flay, a real stdlib Coverage capture). A temp dir keeps the
# coverage absolute-path join honest and means there is no git history, so churn
# is absent and the run is deterministic. The pinned scoring lives in
# test_health_score.rb; here we assert the composition, the join, the schema, and
# graceful degradation.
class TestHealth < Minitest::Test
  def setup
    skip "rubydex unavailable" unless Moult::Index.available?
  end

  ORDER = <<~RUBY
    module Shop
      class Order
        def initialize(items)
          @items = items
        end

        def used
          helper + 1
        end

        def normalize(value)
          result = value.to_s.strip.downcase
          result = result.gsub(/\\s+/, " ")
          result = result.delete_prefix("the ")
          result.tr("_", "-")
        end

        private

        def helper
          @items.length
        end

        def dead_one
          99
        end
      end
    end

    Shop::Order.new([1, 2]).used
  RUBY

  CUSTOMER = <<~RUBY
    module Shop
      class Customer
        def initialize(name)
          @name = name
        end

        def normalize(value)
          result = value.to_s.strip.downcase
          result = result.gsub(/\\s+/, " ")
          result = result.delete_prefix("the ")
          result.tr("_", "-")
        end

        def greeting
          "Hi \#{@name}"
        end
      end
    end
  RUBY

  # Build a temp project (Order + Customer) and capture genuine coverage: Order's
  # `used`/`helper` run (hot); the rest is defined but never called (cold).
  def with_project
    Dir.mktmpdir do |root|
      File.write(File.join(root, "order.rb"), ORDER)
      File.write(File.join(root, "customer.rb"), CUSTOMER)
      cov = File.join(root, "coverage.json")
      capture_coverage(root, cov)
      yield root, cov
    end
  end

  def capture_coverage(root, cov)
    order = File.join(root, "order.rb")
    customer = File.join(root, "customer.rb")
    script = <<~RB
      require "coverage"
      require "json"
      Coverage.start(lines: true)
      load #{order.inspect}
      load #{customer.inspect}
      File.write(#{cov.inspect}, JSON.generate(Coverage.result))
    RB
    flunk "failed to capture coverage" unless system(RbConfig.ruby, "-e", script)
  end

  def build(root, coverage: nil)
    files = Moult::Discovery.ruby_files(root)
    index = Moult::Index.build(root: root, paths: files)
    rails = Moult::RailsConventions.new(rails: false)
    dataset = coverage ? Moult::Coverage.load(coverage, root: root) : nil
    Moult::Health.build_report(root: root, files: files, index: index, rails: rails, coverage: dataset)
  end

  # ---- the composite + the four components ----------------------------------

  def test_components_are_listed_in_order_with_boundaries_skipped_off_packwerk
    with_project do |root, cov|
      report = build(root, coverage: cov)
      names = report.components.map(&:name)
      assert_equal %w[complexity dead_code duplication coverage boundaries], names
      # The four analysis components contributed; boundaries is skipped because the
      # temp project is not packwerk-configured (no packwerk.yml).
      assert(report.components.first(4).all?(&:present), "every analysis contributed")
      boundaries = report.components.find { |c| c.name == "boundaries" }
      refute boundaries.present
      assert_equal "not a packwerk project (no packwerk.yml)", boundaries.diagnostic
      assert_operator report.score, :>=, 0.0
      assert_operator report.score, :<=, 1.0
      assert_includes %w[A B C D F], report.grade
    end
  end

  def test_boundaries_component_is_present_for_a_packwerk_project
    Dir.mktmpdir do |root|
      File.write(File.join(root, "order.rb"), ORDER)
      File.write(File.join(root, "packwerk.yml"), "package_paths:\n  - \"packages/*\"\n")
      todo = "---\npackages/user:\n  \"::User::Account\":\n    violations:\n    - dependency\n    files:\n    - order.rb\n"
      File.write(File.join(root, "package_todo.yml"), todo)

      files = Moult::Discovery.ruby_files(root)
      index = Moult::Index.build(root: root, paths: files)
      rails = Moult::RailsConventions.new(rails: false)
      report = Moult::Health.build_report(root: root, files: files, index: index, rails: rails)

      boundaries = report.components.find { |c| c.name == "boundaries" }
      assert boundaries.present, "a packwerk project contributes the boundaries component"
      assert_equal "architecture_boundary", boundaries.category
      assert_operator boundaries.score, :>=, 0.0
      assert_operator boundaries.score, :<=, 1.0
      assert_equal 1, boundaries.summary[:violation_count]
      # The referencing file rolls up at path granularity (boundary symbol_ids are null).
      order = report.files.find { |f| f.path == "order.rb" }
      refute_nil order
      assert order.components.key?("boundaries")
    end
  end

  def test_composite_is_the_renormalised_weighted_mean_of_present_components
    with_project do |root, cov|
      report = build(root, coverage: cov)
      present = report.components.select(&:present)
      total_w = present.sum { |c| Moult::Health::Score::WEIGHTS.fetch(c.name) }
      expected = present.sum { |c| c.score * Moult::Health::Score::WEIGHTS.fetch(c.name) } / total_w
      assert_in_delta expected.round(2), report.score, 0.001
    end
  end

  # ---- the cross-analysis join (per-file roll-up by symbol_id) --------------

  def test_files_roll_up_and_carry_contributing_symbol_ids
    with_project do |root, cov|
      report = build(root, coverage: cov)
      refute_empty report.files
      report.files.each do |file|
        assert_operator file.score, :>=, 0.0
        assert_operator file.score, :<=, 1.0
        assert_equal file.symbol_ids.size, file.symbol_ids.uniq.size, "join keys are de-duplicated"
        assert_operator file.symbol_count, :>=, file.symbol_ids.size
      end
      # The dead, never-run private method joins through a symbol_id.
      ids = report.files.flat_map(&:symbol_ids)
      assert(ids.any? { |id| id.include?("Shop::Order#dead_one") }, "the dead method is surfaced as a join key")
    end
  end

  def test_real_report_validates_against_the_schema
    with_project do |root, cov|
      data = JSON.parse(JSON.generate(build(root, coverage: cov).to_h))
      errors = schemer("health.schema.json").validate(data).to_a
      assert_empty errors, "schema violations: #{errors.map { |e| e["error"] }.join(", ")}"
    end
  end

  # ---- graceful degradation: no coverage merged -----------------------------

  def test_without_coverage_the_coverage_component_is_skipped
    with_project do |root, _cov|
      report = build(root)
      coverage = report.components.find { |c| c.name == "coverage" }
      refute coverage.present
      assert_nil coverage.score
      assert_equal "no --coverage supplied", coverage.diagnostic
      # The other three still produce a composite.
      assert_operator report.components.count(&:present), :>=, 3
      refute_nil report.score
    end
  end

  # ---- graceful degradation: one analysis raises ----------------------------

  def test_a_failing_analysis_degrades_only_its_component
    with_project do |root, _cov|
      files = Moult::Discovery.ruby_files(root)
      index = Moult::Index.build(root: root, paths: files)
      rails = Moult::RailsConventions.new(rails: false)

      report = Moult::Duplication.stub(:build_report, ->(*) { raise "flay exploded" }) do
        Moult::Health.build_report(root: root, files: files, index: index, rails: rails)
      end

      duplication = report.components.find { |c| c.name == "duplication" }
      refute duplication.present, "the failed analysis is marked absent"
      assert_equal "flay exploded", duplication.diagnostic, "the error message is recorded"
      # Complexity and dead_code still contributed; the run did not crash.
      refute_nil report.score
      assert(report.components.find { |c| c.name == "complexity" }.present)
      assert(report.components.find { |c| c.name == "dead_code" }.present)
    end
  end
end
