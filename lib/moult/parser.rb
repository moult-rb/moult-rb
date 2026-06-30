# frozen_string_literal: true

require "prism"
require_relative "span"

module Moult
  # A single method definition discovered by parsing. Internal to the analysis
  # pipeline (not the serialized {Report::Method}); it retains the Prism node so
  # the ABC metric can walk the method's subtree.
  #
  # +name+ is the *lexical* fully-qualified name (Class#method / Class.method),
  # derived from the written module/class nesting only. Constant resolution
  # (Zeitwerk, includes, reopened constants) is deliberately out of Phase 1.
  MethodDef = Struct.new(:name, :span, :node)

  # Pure parsing layer: source -> list of {MethodDef}. No IO beyond optionally
  # reading a file; no git, no scoring. Trivially unit-testable on snippets.
  module Parser
    module_function

    # @param path [String] file to read and parse
    # @return [Array<MethodDef>]
    def parse_file(path)
      parse_source(File.read(path))
    end

    # @param source [String] Ruby source
    # @return [Array<MethodDef>] in source order
    def parse_source(source)
      result = Prism.parse(source)
      visitor = Visitor.new
      result.value.accept(visitor)
      visitor.methods
    end

    # Walks the AST tracking lexical class/module nesting and `class << self`
    # context so each def gets a fully-qualified lexical name.
    class Visitor < Prism::Visitor
      attr_reader :methods

      def initialize
        @namespace = []         # stack of constant-path strings, e.g. ["A", "B::C"]
        @singleton_context = [] # truthy frame == inside `class << self`
        @methods = []
        super
      end

      def visit_class_node(node)
        @namespace.push(node.constant_path.slice)
        super
        @namespace.pop
      end

      def visit_module_node(node)
        @namespace.push(node.constant_path.slice)
        super
        @namespace.pop
      end

      def visit_singleton_class_node(node)
        # `class << self` makes nested defs singleton (class) methods of the
        # enclosing namespace. Other `class << obj` forms are visited but not
        # specially qualified.
        @singleton_context.push(node.expression.is_a?(Prism::SelfNode))
        super
        @singleton_context.pop
      end

      def visit_def_node(node)
        @methods << MethodDef.new(
          name: qualified_name(node),
          span: span_for(node),
          node: node
        )
        super
      end

      private

      def qualified_name(node)
        singleton = !node.receiver.nil? || @singleton_context.last
        separator = singleton ? "." : "#"
        qualifier = @namespace.join("::")
        return "#{separator}#{node.name}" if qualifier.empty? && singleton
        return node.name.to_s if qualifier.empty?

        "#{qualifier}#{separator}#{node.name}"
      end

      def span_for(node)
        loc = node.location
        Span.new(
          start_line: loc.start_line,
          start_column: loc.start_column,
          end_line: loc.end_line,
          end_column: loc.end_column
        )
      end
    end
  end
end
