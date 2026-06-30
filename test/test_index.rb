# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Live integration test for the rubydex adapter. Skips cleanly when the native
# gem is unavailable so the rest of the suite still runs everywhere; CI with
# rubydex installed exercises the real round-trip that validates the adapter's
# normalisations (0-based -> 1-based lines, name-based method references,
# built-in filtering, singleton-name rewriting).
class TestIndex < Minitest::Test
  def setup
    skip "rubydex unavailable" unless Moult::Index.available?
  end

  SOURCE = <<~RUBY
    module Shop
      class Widget
        def used_method
          helper
        end

        def unused_method
          42
        end

        def self.build
          new
        end

        private

        def helper
          "h"
        end
      end

      LIVE_CONST = 1
      DEAD_CONST = 2
    end

    Shop::Widget.new.used_method
    puts Shop::LIVE_CONST
  RUBY

  def with_indexed_project
    Dir.mktmpdir do |root|
      path = File.join(root, "sample.rb")
      File.write(path, SOURCE)
      yield Moult::Index.build(root: root, paths: [path]), root
    end
  end

  def defn(index, name)
    index.definitions.find { |d| d.name == name }
  end

  def test_resolved_and_lists_only_workspace_definitions
    with_indexed_project do |index, _root|
      assert index.resolved?
      names = index.definitions.map(&:name)
      # No stdlib (Object, Kernel, ...) leaks in.
      assert_includes names, "Shop::Widget#helper"
      refute(names.any? { |n| n.start_with?("Object", "Kernel", "BasicObject") })
    end
  end

  def test_line_numbers_are_one_based
    with_indexed_project do |index, _root|
      # `def used_method` is on line 3 (1-based) of SOURCE.
      assert_equal 3, defn(index, "Shop::Widget#used_method").span.start_line
    end
  end

  def test_method_visibility_is_normalised
    with_indexed_project do |index, _root|
      assert_equal :private, defn(index, "Shop::Widget#helper").visibility
      assert_equal :public, defn(index, "Shop::Widget#used_method").visibility
    end
  end

  def test_singleton_method_name_rewritten
    with_indexed_project do |index, _root|
      build = defn(index, "Shop::Widget.build")
      refute_nil build, "singleton def self.build should be named Shop::Widget.build"
      assert build.singleton
    end
  end

  def test_method_reference_counting_is_name_based
    with_indexed_project do |index, _root|
      # helper + used_method are called; unused_method is not.
      assert_operator defn(index, "Shop::Widget#helper").reference_count, :>=, 1
      assert_operator defn(index, "Shop::Widget#used_method").reference_count, :>=, 1
      assert_equal 0, defn(index, "Shop::Widget#unused_method").reference_count
    end
  end

  def test_constant_reference_counting_resolves
    with_indexed_project do |index, _root|
      assert_operator defn(index, "Shop::LIVE_CONST").reference_count, :>=, 1
      assert_equal 0, defn(index, "Shop::DEAD_CONST").reference_count
      assert_equal :constant, defn(index, "Shop::DEAD_CONST").kind
    end
  end

  def test_symbol_id_matches_scoring_format
    with_indexed_project do |index, _root|
      d = defn(index, "Shop::Widget#unused_method")
      assert_equal "sample.rb:7:Shop::Widget#unused_method", d.symbol_id
    end
  end

  def test_override_of_detects_ancestor_method
    Dir.mktmpdir do |root|
      File.write(File.join(root, "h.rb"), <<~RUBY)
        module H
          class Base
            def run; end
          end

          class Child < Base
            def run; end
            def solo; end
          end

          module Greeter
            def greet; end
          end

          class Person
            include Greeter
            def greet; end
          end
        end
      RUBY
      index = Moult::Index.build(root: root, paths: [File.join(root, "h.rb")])
      assert_equal "H::Base", defn(index, "H::Child#run").override_of
      assert_nil defn(index, "H::Child#solo").override_of
      assert_equal "H::Greeter", defn(index, "H::Person#greet").override_of
    end
  end
end
