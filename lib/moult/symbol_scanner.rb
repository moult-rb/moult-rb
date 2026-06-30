# frozen_string_literal: true

require "prism"

module Moult
  # Collects method names that are referenced *as symbols* passed to Rails-style
  # DSL methods — `before_action :authenticate`, `validate :check`,
  # `helper_method :current_user`, `delegate :name, to: :user`. rubydex's
  # reference index only sees real call sites, so these symbol arguments look
  # like nothing references the method and it would be a false-positive
  # dead-code candidate. This scanner harvests them so {RailsConventions} can
  # treat the named methods as live.
  #
  # It is intentionally name-based and lexically scoped to the enclosing
  # class/module: it returns the set of bare method names referenced by DSL
  # symbols in a file, qualified by the surrounding namespace where known. Over-
  # collecting is safe — a spurious "reference" only lowers a finding's
  # confidence, it can never invent a finding.
  module SymbolScanner
    # DSL methods whose Symbol arguments name a method of the surrounding class.
    CALLBACK_DSL = %w[
      before_action after_action around_action
      append_before_action prepend_before_action
      skip_before_action skip_after_action skip_around_action
      before_filter after_filter around_filter
      before_save after_save before_create after_create
      before_update after_update before_destroy after_destroy
      before_validation after_validation
      after_commit after_rollback after_initialize after_find
      before_action_callback
      validate validates_each
      helper_method
      scope delegate
    ].freeze

    module_function

    # @param source [String] Ruby source
    # @return [Array<String>] referenced names: bare ("authenticate") and, where
    #   a lexical namespace is known, qualified ("Foo::Bar#authenticate").
    def scan_source(source)
      result = Prism.parse(source)
      visitor = Visitor.new
      result.value.accept(visitor)
      visitor.referenced_names.to_a
    end

    # @param path [String]
    # @return [Array<String>]
    def scan_file(path)
      scan_source(File.read(path))
    end

    # Walks the tree tracking lexical nesting (mirroring {Parser::Visitor}) so a
    # collected symbol can be attributed to its enclosing class.
    class Visitor < Prism::Visitor
      attr_reader :referenced_names

      def initialize
        @namespace = []
        @referenced_names = []
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

      def visit_call_node(node)
        collect(node) if CALLBACK_DSL.include?(node.name.to_s)
        super
      end

      private

      def collect(node)
        symbol_arguments(node).each do |sym|
          @referenced_names << sym
          qualifier = @namespace.join("::")
          @referenced_names << "#{qualifier}##{sym}" unless qualifier.empty?
        end
      end

      def symbol_arguments(node)
        args = node.arguments&.arguments || []
        args.filter_map do |arg|
          arg.unescaped if arg.is_a?(Prism::SymbolNode)
        end
      end
    end
  end
end
