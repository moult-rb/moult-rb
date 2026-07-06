# frozen_string_literal: true

require "rubydex"
require_relative "span"
require_relative "symbol_id"

module Moult
  # The definition/reference index — Moult's adapter over the +rubydex+ gem and
  # the *only* file that names +Rubydex+. Everything downstream consumes the
  # Moult-owned {Index::Definition} value object, never a rubydex type, so the
  # backend is swappable (the "swap, not rewrite" invariant).
  #
  # rubydex has two quirks this adapter normalises away (see test/test_index.rb):
  #
  # * Its locations are 0-based; Moult/Prism are 1-based. We add 1 to line
  #   numbers so dead-code symbol ids line up with {Scoring}'s hotspot ids.
  # * Method references are not resolved to their target declaration (only
  #   constants are). So a method is considered "referenced" when its bare name
  #   appears anywhere in the call-site collection. This is deliberately
  #   conservative: a name collision can only *hide* a dead method, never invent
  #   a false positive — the safe direction for a confidence-graded tool.
  class Index
    # A definition site that is a candidate for the dead-code analysis. All
    # fields are Moult-owned; no rubydex object leaks past this struct.
    #
    # @!attribute kind        [Symbol] :method or :constant
    # @!attribute visibility  [Symbol] :public, :private, :protected
    # @!attribute singleton   [Boolean] true for Class.method / constants
    # @!attribute reference_count [Integer] resolvable usages of this definition
    # @!attribute reference_paths [Array<String>] root-relative paths that use it
    # @!attribute override_of [String, nil] FQ name of the ancestor whose method
    #   this overrides/implements (reachable via that interface), else nil
    # @!attribute owner_hierarchy_reference_paths [Array<String>, nil] for
    #   methods: root-relative paths referencing the owner type or any
    #   descendant, excluding the hierarchy's own definition files. nil when
    #   the owner is unknown or defined outside the workspace (fact
    #   unavailable), and always nil for constants (their own reference_paths
    #   already carry the signal)
    Definition = Struct.new(
      :symbol_id, :kind, :name, :unqualified_name, :owner,
      :visibility, :singleton, :span, :path,
      :reference_count, :reference_paths, :override_of,
      :owner_hierarchy_reference_paths
    )

    # One resolved constant-reference dependency between two workspace files.
    # +constant+/+span+ identify a representative reference site (the earliest
    # in +src+), kept as evidence rather than every duplicate site.
    Edge = Struct.new(:src, :dst, :constant, :span)

    BUILTIN_SCHEME = "file:"

    class << self
      # @param root [String] absolute analysis root
      # @param paths [Array<String>] absolute paths of Ruby files to index
      # @return [Index]
      def build(root:, paths:)
        graph = Rubydex::Graph.new
        graph.index_all(Array(paths))
        graph.resolve
        new(graph: graph, root: root)
      rescue => e
        raise Moult::Error, "rubydex indexing failed: #{e.class}: #{e.message}"
      end

      # Whether the rubydex backend is loadable. Always true once the gem is a
      # hard dependency, but kept so live integration tests can skip cleanly.
      def available?
        require "rubydex"
        true
      rescue LoadError
        false
      end
    end

    def initialize(graph:, root:)
      @graph = graph
      # rubydex reports canonical (symlink-resolved) paths, so the root must be
      # canonicalised too or workspace filtering misses everything on systems
      # where e.g. /tmp -> /private/tmp.
      @root = File.realpath(root.to_s)
    rescue Errno::ENOENT
      @root = root.to_s
    end

    # @return [Array<Index::Definition>] method + constant definition sites
    #   defined within the workspace, each with its resolved reference count.
    def definitions
      @definitions ||= method_definitions + constant_definitions
    end

    def resolved?
      true
    end

    # @return [Array<String>] human-readable index diagnostics (non-fatal).
    def diagnostics
      @graph.diagnostics.map(&:to_s)
    rescue
      []
    end

    # @return [Array<Index::Edge>] unique src->dst file dependencies from
    #   resolved constant references (superclass and mixin clauses flow through
    #   the same list, so inheritance edges are included). A constant reopened
    #   in N files yields an edge to every in-workspace definition file;
    #   self-edges and qualifier segments are dropped. Sorted by [src, dst] so
    #   output is byte-stable regardless of rubydex iteration order.
    def file_edges
      @file_edges ||= begin
        edges = {}
        resolved = @graph.constant_references.select { |r| r.is_a?(Rubydex::ResolvedConstantReference) }
        qualifiers = qualifier_references(resolved)
        resolved.each do |ref|
          next if qualifiers.include?(ref)
          src = workspace_relative(ref.location)
          next unless src
          span = span_from(ref.location)
          in_workspace_definitions(ref.declaration).each do |_defn, _span, dst|
            next if dst == src
            existing = edges[[src, dst]]
            next if existing && existing.span.start_line <= span.start_line
            edges[[src, dst]] = Edge.new(src: src, dst: dst, constant: ref.declaration.name, span: span)
          end
        end
        edges.values.sort_by { |e| [e.src, e.dst] }
      end
    end

    private

    def method_definitions
      @graph.declarations.select { |d| d.is_a?(Rubydex::Method) }.flat_map do |decl|
        name = normalize_name(decl.name)
        unqualified = strip_signature(decl.unqualified_name)
        sites = method_call_sites[unqualified]
        override = override_source(decl)
        hierarchy_refs = hierarchy_reference_paths(decl.owner)
        in_workspace_definitions(decl).map do |defn, span, rel|
          Definition.new(
            symbol_id: SymbolId.for(path: rel, start_line: span.start_line, fqname: name),
            kind: :method,
            name: name,
            unqualified_name: unqualified,
            owner: decl.owner&.name,
            visibility: visibility_of(decl),
            singleton: !name.include?("#"),
            span: span,
            path: rel,
            reference_count: sites.size,
            reference_paths: sites.compact.uniq,
            override_of: override,
            owner_hierarchy_reference_paths: hierarchy_refs
          )
        end
      end
    end

    def constant_definitions
      @graph.declarations.select { |d| d.is_a?(Rubydex::Constant) }.flat_map do |decl|
        refs = constant_reference_paths(decl)
        in_workspace_definitions(decl).map do |defn, span, rel|
          Definition.new(
            symbol_id: SymbolId.for(path: rel, start_line: span.start_line, fqname: decl.name),
            kind: :constant,
            name: decl.name,
            unqualified_name: strip_signature(decl.unqualified_name),
            owner: decl.owner&.name,
            visibility: visibility_of(decl),
            singleton: true,
            span: span,
            path: rel,
            reference_count: refs.size,
            reference_paths: refs.compact.uniq,
            override_of: nil
          )
        end
      end
    end

    # rubydex does not resolve method references to a target, so we index every
    # call site by its bare name: { "perform" => ["app/jobs/x.rb", ...] }.
    def method_call_sites
      @method_call_sites ||= @graph.method_references.each_with_object(Hash.new { |h, k| h[k] = [] }) do |ref, acc|
        acc[ref.name.to_s] << workspace_relative(ref.location)
      end
    end

    def constant_reference_paths(decl)
      decl.references.map { |ref| workspace_relative(ref.location) }
    rescue
      []
    end

    # @return [Array<[definition, Span, rel_path]>] only sites inside the workspace
    def in_workspace_definitions(decl)
      decl.definitions.filter_map do |defn|
        loc = defn.location
        next unless in_workspace?(loc)
        [defn, span_from(loc), workspace_relative(loc)]
      end
    end

    # The qualifier segments of constant paths. In `Moult::Error`, rubydex
    # records a resolved reference for the `Moult` token as well as one for
    # `Error` — but the file dependency is on where *Error* is defined. A root
    # namespace reopened in every file (`module Moult` in each) would otherwise
    # fan edges out to the entire codebase, drowning the graph. A reference is
    # a qualifier when a same-line reference to a deeper constant in its own
    # namespace starts exactly two columns (the `::`) after it ends.
    def qualifier_references(resolved)
      by_line = resolved.group_by { |r| [r.location&.uri, r.location&.start_line] }
      resolved.each_with_object(Set.new) do |ref, quals|
        loc = ref.location
        next unless loc
        deeper = "#{ref.declaration.name}::"
        quals << ref if by_line[[loc.uri, loc.start_line]].any? do |other|
          other.declaration.name.start_with?(deeper) &&
            other.location.start_column == loc.end_column + 2
        end
      end
    end

    def in_workspace?(location)
      return false unless location
      uri = location.uri
      return false unless uri&.start_with?(BUILTIN_SCHEME)
      file_path(location)&.start_with?(@root) || false
    end

    def workspace_relative(location)
      path = file_path(location)
      return nil unless path&.start_with?(@root)
      SymbolId.relative_path(path, @root)
    end

    def file_path(location)
      return nil unless location&.uri&.start_with?(BUILTIN_SCHEME)
      location.to_file_path
    rescue
      nil
    end

    # rubydex lines are 0-based; Moult/Prism are 1-based. Columns already align.
    def span_from(location)
      Span.new(
        start_line: location.start_line + 1,
        start_column: location.start_column,
        end_line: location.end_line + 1,
        end_column: location.end_column
      )
    end

    # The FQ name of the nearest ancestor (superclass or included module) that
    # defines a method of the same name — meaning this definition overrides or
    # implements it and is reachable through that ancestor's interface
    # (polymorphic dispatch). nil when it overrides nothing in-workspace. Members
    # are keyed by their signature form ("call()"), so the raw unqualified_name
    # is the correct lookup key. External ancestors (gems) are only visible when
    # their source has been indexed.
    def override_source(decl)
      owner = decl.owner
      return nil unless owner
      member_name = decl.unqualified_name
      owner.ancestors.each do |ancestor|
        next if ancestor.name == owner.name
        return ancestor.name unless ancestor.member(member_name).nil?
      end
      nil
    rescue
      nil
    end

    # Production-reachability of a method's receiver type: the root-relative
    # paths of constant references to the owner namespace or any descendant,
    # minus the hierarchy's own definition files — a subclass's `< Base`
    # clause is itself a reference to Base and would otherwise make the result
    # never empty. nil when the owner is unknown or defined outside the
    # workspace (Object, gems): the fact is unavailable, not "unreferenced".
    # Cached per owner so one descendants walk serves all of its methods.
    def hierarchy_reference_paths(owner)
      return nil unless owner
      @hierarchy_refs ||= {}
      return @hierarchy_refs[owner.name] if @hierarchy_refs.key?(owner.name)
      @hierarchy_refs[owner.name] = begin
        # def self.x lives on the singleton class; judge the class itself.
        target = owner.is_a?(Rubydex::SingletonClass) ? owner.attached_class : owner
        if target.is_a?(Rubydex::Namespace)
          namespaces = ([target] + target.descendants.to_a).uniq(&:name)
          own_files = namespaces.flat_map { |ns| in_workspace_definitions(ns).map { |_defn, _span, rel| rel } }.uniq
          unless own_files.empty?
            namespaces.flat_map { |ns| ns.references.map { |ref| workspace_relative(ref.location) } }
              .compact.uniq - own_files
          end
        end
      rescue
        nil
      end
    end

    def visibility_of(decl)
      vis = decl.visibility if decl.respond_to?(:visibility)
      %i[public private protected].include?(vis) ? vis : :public
    end

    # "Shop::Widget#helper()" => "Shop::Widget#helper";
    # singleton "Acme::Service::<Service>#build()" => "Acme::Service.build"
    def normalize_name(raw)
      strip_signature(raw.to_s).sub(/::<[^>]+>#/, ".")
    end

    def strip_signature(raw)
      raw.to_s.sub(/\(.*\z/m, "")
    end
  end
end
