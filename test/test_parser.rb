# frozen_string_literal: true

require "test_helper"

class TestParser < Minitest::Test
  def names(source)
    Moult::Parser.parse_source(source).map(&:name)
  end

  def test_top_level_instance_method
    assert_equal ["greet"], names("def greet; end")
  end

  def test_top_level_singleton_method
    assert_equal [".run"], names("def self.run; end")
  end

  def test_nested_namespace_instance_method
    source = <<~RUBY
      module A
        class B
          def foo(x)
            x + 1
          end
        end
      end
    RUBY
    assert_equal ["A::B#foo"], names(source)
  end

  def test_singleton_method_via_self_receiver
    source = <<~RUBY
      class Widget
        def self.build
        end
      end
    RUBY
    assert_equal ["Widget.build"], names(source)
  end

  def test_singleton_method_via_singleton_class
    source = <<~RUBY
      class Widget
        class << self
          def build; end
          def teardown; end
        end
      end
    RUBY
    assert_equal ["Widget.build", "Widget.teardown"], names(source)
  end

  def test_compact_namespace_definition
    source = <<~RUBY
      class A::B
        def call; end
      end
    RUBY
    assert_equal ["A::B#call"], names(source)
  end

  def test_collects_multiple_methods_in_source_order
    source = <<~RUBY
      class C
        def a; end
        def b; end
        def self.c; end
      end
    RUBY
    assert_equal ["C#a", "C#b", "C.c"], names(source)
  end

  def test_span_is_one_based_lines_zero_based_columns
    source = <<~RUBY
      class C
        def foo
          1
        end
      end
    RUBY
    method = Moult::Parser.parse_source(source).first
    span = method.span
    assert_equal 2, span.start_line
    assert_equal 2, span.start_column
    assert_equal 4, span.end_line
    assert_equal 5, span.end_column
  end

  def test_retains_prism_node_for_downstream_metrics
    method = Moult::Parser.parse_source("def foo; end").first
    assert_kind_of Prism::DefNode, method.node
  end

  def test_empty_source_yields_no_methods
    assert_empty Moult::Parser.parse_source("")
  end
end
