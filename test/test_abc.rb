# frozen_string_literal: true

require "test_helper"

# These cases are hand-counted against the documented scoring rules in
# Moult::ABC. Any drift here is a metric bug, not a test to "fix".
class TestABC < Minitest::Test
  def score(source)
    method = Moult::Parser.parse_source(source).first
    Moult::ABC.score(method.node)
  end

  def assert_score(expected, source)
    assert_in_delta expected, score(source), 0.001, "score for: #{source.inspect}"
  end

  def test_empty_method_scores_zero
    assert_score 0.0, "def f; end"
  end

  def test_single_assignment
    # 1 assignment
    assert_score 1.0, "def f; x = 1; end"
  end

  def test_operator_assignment_counts_once
    # op-assign is a single assignment; the operator is not double-counted
    assert_score 1.0, "def f; x += 1; end"
  end

  def test_assignment_with_calls_in_rhs
    # assignment(1) + call(:+)(1) + call(:foo)(1)
    assert_score 3.0, "def f; x = foo + 1; end"
  end

  def test_two_calls
    # call(:puts)(1) + call(:bar)(1)
    assert_score 2.0, "def f; puts(bar); end"
  end

  def test_simple_condition_applies_depth_to_children
    # if(1.0) + predicate a(1.1) + body b(1.1)
    assert_score 3.2, "def f; if a; b; end; end"
  end

  def test_nested_conditions_compound
    # if(1.0) + a(1.1) + inner-if(1.1) + b(1.21) + c(1.21)
    assert_score 5.62, "def f; if a; if b; c; end; end; end"
  end

  def test_while_loop
    # while(1.0) + a(1.1) + b(1.1)
    assert_score 3.2, "def f; while a; b; end; end"
  end

  def test_case_when_counts_each_branch
    # case(1.0) + x(1.1) + when(1.1) + a(1.1) + when(1.1) + b(1.1)
    assert_score 6.5, "def f; case x; when 1; a; when 2; b; end; end"
  end

  def test_boolean_operators_are_conditions
    # or(1) + and(1) + a(1) + b(1) + c(1); &&/|| do not add depth
    assert_score 5.0, "def f; a && b || c; end"
  end

  def test_block_adds_depth_to_its_body
    # each(1.0) + items(1.0) + save(1.1, one level deep in the block)
    assert_score 3.1, "def f; items.each { |i| i.save }; end"
  end

  def test_magic_send_is_penalised
    # send(3.0) + obj(1.0)
    assert_score 4.0, "def f; obj.send(:x); end"
  end

  def test_define_method_is_penalised
    # define_method(4.0); block body literal contributes nothing
    assert_score 4.0, "def f; define_method(:x) { 1 }; end"
  end

  def test_nested_def_is_not_counted_into_outer
    # The outer method's own body is empty; the inner def is scored separately.
    source = <<~RUBY
      def outer
        def inner
          x = foo + 1
        end
      end
    RUBY
    methods = Moult::Parser.parse_source(source)
    outer = methods.find { |m| m.name == "outer" }
    inner = methods.find { |m| m.name == "inner" }
    assert_in_delta 0.0, Moult::ABC.score(outer.node), 0.001
    assert_in_delta 3.0, Moult::ABC.score(inner.node), 0.001
  end
end
