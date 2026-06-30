# frozen_string_literal: true

require "prism"

module Moult
  # The OpenFeature flag-evaluation SCANNER — the *only* file that knows the
  # OpenFeature client call shape, so a future SDK or provider shift is a swap,
  # not a rewrite (the same isolation {Clones} gives flay and {Boundaries::Packwerk}
  # gives packwerk). It is a pure Prism scan over source, shaped like
  # {SymbolScanner}: there is no external-tool output to ingest here.
  #
  # OpenFeature (github.com/open-feature/ruby-sdk, gem +openfeature-sdk+) is the
  # provider-agnostic feature-flag *standard*: a client is built via
  # +OpenFeature::SDK.build_client+ and flags are evaluated with
  # +client.fetch_<type>_value(flag_key:, default_value:, evaluation_context:)+
  # (and the +fetch_<type>_details+ variants). Scanning that client surface catches
  # flag usage behind *any* provider (flagd, LaunchDarkly, GO Feature Flag, ...).
  #
  # We detect by AST only and take NO dependency on the openfeature-sdk gem — we
  # read the call shape, we never call the SDK. A call is an OpenFeature evaluation
  # when its method name is one of the known +fetch_*+ names AND it passes a
  # +flag_key:+ keyword argument (the keyword uniquely disambiguates it from any
  # unrelated same-named method, since the receiver is a runtime value).
  module FlagScanner
    # Provenance recorded in the report's `analysis.scanner` block. The swap point:
    # retarget these (and {METHOD_VALUE_TYPES}) for a different SDK/standard.
    TARGET = "openfeature"
    SDK_GEM = "openfeature-sdk"
    CLIENT_BUILDER = "OpenFeature::SDK.build_client"

    # The fetch_<type>_(value|details) method names mapped to the contract's
    # value_type. integer/float collapse to "number" (the value_type enum is
    # coarser than the SDK's fetch types); the precise method name is kept on each
    # call site so nothing is lost.
    FETCH_TYPES = {
      "boolean" => "boolean",
      "string" => "string",
      "number" => "number",
      "integer" => "number",
      "float" => "number",
      "object" => "object"
    }.freeze

    METHOD_VALUE_TYPES = FETCH_TYPES.each_with_object({}) do |(fetch_type, value_type), acc|
      acc["fetch_#{fetch_type}_value"] = value_type
      acc["fetch_#{fetch_type}_details"] = value_type
    end.freeze

    # The literal default_value node types we render. A non-literal default (a
    # variable, method call, array/hash) renders to nil — recorded as "no observed
    # literal default" rather than guessed.
    LITERAL_NODES = [
      Prism::StringNode, Prism::SymbolNode, Prism::IntegerNode,
      Prism::FloatNode, Prism::TrueNode, Prism::FalseNode, Prism::NilNode
    ].freeze

    # One detected OpenFeature flag-evaluation call site. +flag_key+ is nil when the
    # key is not a string/symbol literal (a *dynamic* reference: counted by the
    # report, never catalogued, since a static scan cannot resolve it).
    CallSite = Struct.new(:flag_key, :value_type, :default_value, :method_name, :path, :line)

    module_function

    # @param path [String] file to read
    # @param rel_path [String] root-relative path stamped onto each call site
    # @return [Array<CallSite>]
    def scan_file(path, rel_path)
      scan_source(File.read(path), rel_path)
    end

    # @param source [String] Ruby source
    # @param path [String] path stamped onto each call site
    # @return [Array<CallSite>]
    def scan_source(source, path)
      result = Prism.parse(source)
      visitor = Visitor.new(path)
      result.value.accept(visitor)
      visitor.call_sites
    end

    # Walks the AST collecting OpenFeature flag-evaluation calls. No namespace
    # tracking is needed: line→enclosing-method attribution is the orchestration's
    # job (a {Flags::MethodIndex}, reusing the Prism {Parser}), keyed on the line
    # recorded here.
    class Visitor < Prism::Visitor
      attr_reader :call_sites

      def initialize(path)
        @path = path
        @call_sites = []
        super()
      end

      def visit_call_node(node)
        capture(node)
        super
      end

      private

      def capture(node)
        value_type = METHOD_VALUE_TYPES[node.name.to_s]
        return unless value_type

        kwargs = keyword_arguments(node)
        return unless kwargs.key?("flag_key")

        @call_sites << CallSite.new(
          literal_key(kwargs["flag_key"]),
          value_type,
          literal_default(kwargs["default_value"]),
          node.name.to_s,
          @path,
          node.location.start_line
        )
      end

      # Map of keyword name (String) => value node, for the trailing keyword hash.
      def keyword_arguments(node)
        args = node.arguments&.arguments || []
        hash = args.find { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
        return {} unless hash

        hash.elements.each_with_object({}) do |assoc, acc|
          next unless assoc.is_a?(Prism::AssocNode)
          key = assoc.key
          acc[key.unescaped] = assoc.value if key.is_a?(Prism::SymbolNode)
        end
      end

      # The flag key when it is a string/symbol literal; nil otherwise (dynamic).
      def literal_key(node)
        case node
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        end
      end

      # A string rendering of a literal default value, or nil when not a literal.
      def literal_default(node)
        return nil unless node && LITERAL_NODES.any? { |k| node.is_a?(k) }

        case node
        when Prism::StringNode then node.unescaped
        when Prism::SymbolNode then ":#{node.unescaped}"
        else node.slice
        end
      end
    end
  end
end
