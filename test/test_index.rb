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

  def test_file_edges_from_mutual_constant_references
    Dir.mktmpdir do |root|
      File.write(File.join(root, "a.rb"), <<~RUBY)
        class A
          def touch = B
        end
      RUBY
      File.write(File.join(root, "b.rb"), <<~RUBY)
        class B
          def touch = A
        end
      RUBY
      index = Moult::Index.build(root: root, paths: [File.join(root, "a.rb"), File.join(root, "b.rb")])
      edges = index.file_edges
      assert_equal [%w[a.rb b.rb], %w[b.rb a.rb]], edges.map { |e| [e.src, e.dst] }
      a_to_b = edges.first
      assert_equal "B", a_to_b.constant
      assert_equal 2, a_to_b.span.start_line # `def touch = B` is on line 2, 1-based
    end
  end

  def test_file_edges_reopened_constant_targets_every_definition_file
    Dir.mktmpdir do |root|
      File.write(File.join(root, "c.rb"), "class C; end\n")
      File.write(File.join(root, "c2.rb"), "class C; def more; end; end\n")
      File.write(File.join(root, "a.rb"), "A = C\n")
      paths = %w[c.rb c2.rb a.rb].map { |f| File.join(root, f) }
      index = Moult::Index.build(root: root, paths: paths)
      assert_equal [%w[a.rb c.rb], %w[a.rb c2.rb]], index.file_edges.map { |e| [e.src, e.dst] }
    end
  end

  def test_file_edges_skips_qualifier_segments_of_constant_paths
    Dir.mktmpdir do |root|
      # `module NS` is reopened in both files, so a qualifier edge for the
      # `NS` token in `NS::Target` would reach every file in the namespace.
      File.write(File.join(root, "target.rb"), "module NS\n  class Target\n  end\nend\n")
      File.write(File.join(root, "other.rb"), "module NS\n  class Other\n  end\nend\n")
      File.write(File.join(root, "user.rb"), "class User\n  def touch = NS::Target\nend\n")
      paths = %w[target.rb other.rb user.rb].map { |f| File.join(root, f) }
      index = Moult::Index.build(root: root, paths: paths)

      assert_equal [%w[user.rb target.rb]], index.file_edges.map { |e| [e.src, e.dst] }
      assert_equal "NS::Target", index.file_edges.first.constant
    end
  end

  def test_file_edges_drops_self_edges_and_builtins
    with_indexed_project do |index, _root|
      # SOURCE references Shop::Widget and Shop::LIVE_CONST from within
      # sample.rb itself, and Object/Kernel via puts/new.
      assert_empty index.file_edges
    end
  end

  def test_owner_hierarchy_reference_paths_on_a_dead_tree
    Dir.mktmpdir do |root|
      File.write(File.join(root, "base.rb"), "class Base\n  def run; end\nend\n")
      File.write(File.join(root, "child.rb"), "class Child < Base\n  def run; end\nend\n")
      paths = [File.join(root, "base.rb"), File.join(root, "child.rb")]
      index = Moult::Index.build(root: root, paths: paths)

      # The `< Base` clause is a reference from inside the hierarchy's own
      # files, so both methods see a provably-unreferenced tree.
      assert_equal [], defn(index, "Base#run").owner_hierarchy_reference_paths
      assert_equal [], defn(index, "Child#run").owner_hierarchy_reference_paths
    end
  end

  def test_descendant_reference_counts_for_the_ancestors_methods
    Dir.mktmpdir do |root|
      File.write(File.join(root, "base.rb"), "class Base\n  def run; end\nend\n")
      File.write(File.join(root, "child.rb"), "class Child < Base\nend\n")
      File.write(File.join(root, "caller.rb"), "X = Child\n")
      paths = %w[base.rb child.rb caller.rb].map { |f| File.join(root, f) }
      index = Moult::Index.build(root: root, paths: paths)

      assert_equal ["caller.rb"], defn(index, "Base#run").owner_hierarchy_reference_paths
    end
  end

  def test_singleton_method_judges_the_attached_class
    Dir.mktmpdir do |root|
      File.write(File.join(root, "svc.rb"), "class Svc\n  def self.build; end\nend\n")
      File.write(File.join(root, "caller.rb"), "X = Svc\n")
      paths = [File.join(root, "svc.rb"), File.join(root, "caller.rb")]
      index = Moult::Index.build(root: root, paths: paths)

      assert_equal ["caller.rb"], defn(index, "Svc.build").owner_hierarchy_reference_paths
    end
  end

  def test_module_hierarchy_degrades_gracefully
    Dir.mktmpdir do |root|
      File.write(File.join(root, "m.rb"), "module Helper\n  def assist; end\nend\n")
      File.write(File.join(root, "user.rb"), "class User\n  include Helper\nend\n")
      paths = [File.join(root, "m.rb"), File.join(root, "user.rb")]
      index = Moult::Index.build(root: root, paths: paths)

      # Exploratory pin: whatever rubydex 0.2.6 returns for a module's
      # descendants, the field must be an Array or nil — either degrades
      # gracefully in the confidence rule (fires less or not at all).
      value = defn(index, "Helper#assist").owner_hierarchy_reference_paths
      assert value.nil? || value.is_a?(Array), "got #{value.inspect}"
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
