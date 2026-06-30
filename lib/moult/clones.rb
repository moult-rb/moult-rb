# frozen_string_literal: true

require "flay"
require_relative "symbol_id"

module Moult
  # The structural-clone detector — Moult's adapter over the +flay+ gem and the
  # *only* file that names +Flay+. Everything downstream consumes the Moult-owned
  # {Clones::Result} value object, never a flay type, so the backend is swappable
  # (the "swap, not rewrite" invariant). This is the duplication-slice
  # analogue of {Index} (rubydex) and {Coverage} (SimpleCov/stdlib).
  #
  # flay reports the *largest* duplicated S-expression node, grouping structurally
  # equivalent code (literal values, variable/method/class names and whitespace are
  # all ignored when hashing). Two distinctions it draws map onto our confidence
  # grade:
  #
  # * +bonus+ truthy => the nodes are byte-for-byte IDENTICAL (names and all) —
  #   the clearest copy-paste signal. We surface this as +kind: :identical+.
  # * +bonus+ nil => structurally SIMILAR (same shape, differing names/literals) —
  #   real duplication but weaker (could be parallel-by-design). +kind: :similar+.
  #
  # As of flay 2.14 the default parser is +Flay::NotRubyParser+, which parses with
  # Prism (the same parser Moult uses); no parallel parser stack is pulled in.
  module Clones
    module_function

    # One structurally-equivalent clone group. +node_type+ is flay's sexp type
    # (e.g. :defn, :call, :class). +occurrences+ are the sites, in source order.
    CloneSet = Struct.new(:structural_hash, :node_type, :kind, :mass, :occurrences)

    # A single site of a clone group. +path+ is root-relative; +line+ is flay's
    # reported start line (flay works at line granularity). +fuzzy+ is true only
    # for a near-match node surfaced in fuzzy mode.
    Occurrence = Struct.new(:path, :line, :fuzzy)

    # The Moult-owned result of a detection run. Carries the provenance the
    # contract records; +backend+/+backend_version+ originate here so "flay" stays
    # isolated to this file.
    Result = Struct.new(:sets, :backend, :backend_version, :min_mass, :fuzzy)

    # @param root [String] absolute analysis root (occurrence paths are relative to it)
    # @param files [Array<String>] absolute Ruby file paths to scan
    # @param min_mass [Integer] flay's mass threshold; smaller fragments are ignored
    # @param fuzzy [Boolean] also report near-matches (off by default: deterministic)
    # @return [Result]
    def detect(root:, files:, min_mass: DEFAULT_MIN_MASS, fuzzy: false)
      sets = files.empty? ? [] : run_flay(files, min_mass, fuzzy).filter_map { |item| clone_set(item, root) }
      Result.new(
        sets: sets,
        backend: "flay",
        backend_version: backend_version,
        min_mass: min_mass,
        fuzzy: fuzzy
      )
    end

    # flay's own default mass threshold; small enough to catch a duplicated method,
    # large enough to skip incidental structural rhymes.
    DEFAULT_MIN_MASS = 16

    def run_flay(files, min_mass, fuzzy)
      flay = Flay.new(Flay.default_options.merge(mass: min_mass, fuzzy: fuzzy))
      flay.process(*files)
      flay.analyze
    rescue => e
      raise Moult::Error, "flay duplication scan failed: #{e.class}: #{e.message}"
    end

    def clone_set(item, root)
      occurrences = item.locations.map do |loc|
        Occurrence.new(
          path: SymbolId.relative_path(loc.file, root),
          line: loc.line,
          fuzzy: !loc.fuzzy.nil?
        )
      end
      CloneSet.new(
        structural_hash: item.structural_hash,
        node_type: item.name.to_s,
        kind: item.bonus ? :identical : :similar,
        mass: item.mass,
        occurrences: occurrences
      )
    end

    def backend_version
      defined?(Flay::VERSION) ? Flay::VERSION : nil
    end
  end
end
