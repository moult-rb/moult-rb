# frozen_string_literal: true

require "prism"

module Moult
  # Flog-style weighted ABC complexity for a single method.
  #
  # This is *not* the bare ABC metric (sqrt(A^2 + B^2 + C^2)). Following flog,
  # the score is a weighted *sum* of three buckets, with metaprogramming calls
  # penalised and a compounding depth penalty for nesting:
  #
  #   * A - Assignments: any write node (`=`, op-assign, `||=`, multi-assign,
  #     `obj.x =`, `arr[i] =`). Weight {ASSIGNMENT}. Counted once per write node.
  #   * B - Branches: every message send ({Prism::CallNode}, including operators
  #     like `+` and `==` and index `[]`), plus `yield` and `super`. Weight
  #     {BRANCH}, except metaprogramming calls in {MAGIC_CALLS}, which weigh more.
  #   * C - Conditions: decision nodes - if/unless/while/until/for, case + each
  #     when/in, rescue, and `&&`/`||`. Weight {CONDITION}.
  #
  # Depth penalty: contributions nested inside a control structure or block are
  # multiplied by {DEPTH_FACTOR} per level, compounding. A call directly in the
  # method body weighs 1.0; the same call one `if` deep weighs 1.1; two deep,
  # 1.21; and so on.
  #
  # flog is the reference for the *shape* of this metric; the exact weights below
  # are the ones Moult adopts and are pinned by hand-counted fixtures. Treat any
  # drift from those fixtures as a metric bug.
  module ABC
    ASSIGNMENT = 1.0
    BRANCH = 1.0
    CONDITION = 1.0

    # Each level of control-flow / block nesting compounds contributions by 10%.
    DEPTH_FACTOR = 1.1

    # Metaprogramming and dynamic-dispatch calls weigh more than an ordinary
    # send, mirroring flog's penalties for hard-to-follow Ruby.
    MAGIC_CALLS = {
      eval: 5.0,
      instance_eval: 5.0,
      class_eval: 5.0,
      module_eval: 5.0,
      class_exec: 5.0,
      instance_exec: 5.0,
      define_method: 4.0,
      define_singleton_method: 4.0,
      method_missing: 4.0,
      alias_method: 2.0,
      send: 3.0,
      __send__: 3.0,
      public_send: 3.0
    }.freeze

    BRANCH_NODES = [
      Prism::CallNode,
      Prism::YieldNode,
      Prism::SuperNode,
      Prism::ForwardingSuperNode
    ].freeze

    CONDITION_NODES = [
      Prism::IfNode,
      Prism::UnlessNode,
      Prism::WhileNode,
      Prism::UntilNode,
      Prism::ForNode,
      Prism::CaseNode,
      Prism::CaseMatchNode,
      Prism::WhenNode,
      Prism::InNode,
      Prism::RescueNode,
      Prism::AndNode,
      Prism::OrNode
    ].freeze

    # Nodes whose children sit one nesting level deeper. Containers only - the
    # when/in/&&/|| conditions don't bump again on top of their container.
    NESTING_NODES = [
      Prism::IfNode,
      Prism::UnlessNode,
      Prism::WhileNode,
      Prism::UntilNode,
      Prism::ForNode,
      Prism::CaseNode,
      Prism::CaseMatchNode,
      Prism::RescueNode,
      Prism::BlockNode,
      Prism::LambdaNode
    ].freeze

    module_function

    # @param def_node [Prism::DefNode] a method definition
    # @return [Float] the method's weighted ABC score, rounded to 2 decimals
    def score(def_node)
      total = walk(def_node, 1.0, root: true)
      total.round(2)
    end

    # Recursively accumulate weighted contributions. Nested `def`s are scored
    # independently (they're separate methods), so we don't descend into them.
    def walk(node, multiplier, root: false)
      return 0.0 if node.is_a?(Prism::DefNode) && !root

      total = weight_for(node) * multiplier
      child_multiplier = NESTING_NODES.include?(node.class) ? multiplier * DEPTH_FACTOR : multiplier
      node.compact_child_nodes.each do |child|
        total += walk(child, child_multiplier)
      end
      total
    end

    # The weight this node itself contributes (before the depth multiplier).
    def weight_for(node)
      case node
      when Prism::CallNode
        MAGIC_CALLS.fetch(node.name, BRANCH)
      else
        return BRANCH if BRANCH_NODES.include?(node.class)
        return ASSIGNMENT if assignment?(node)
        return CONDITION if CONDITION_NODES.include?(node.class)

        0.0
      end
    end

    # Every Prism assignment node class ends in "WriteNode" (plain writes,
    # operator writes, ||=/&&= writes, multi-writes, and index/attr writes).
    def assignment?(node)
      node.class.name.end_with?("WriteNode")
    end
  end
end
