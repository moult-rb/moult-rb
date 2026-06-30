# frozen_string_literal: true

module Moult
  # The in-memory result model and the source of the typed JSON output
  # contract. This is one of Moult's two protected APIs (the other being the
  # per-finding confidence model). Every analysis must be swappable behind this
  # shape without changing it; both formatters render from this object so they
  # cannot drift.
  #
  # The model reserves +confidence+ and +category+ on every finding even though
  # Phase 1 never populates them: findings are confidence-graded, never asserted
  # as certain death. Phases 2+ fill these in without a schema_version bump.
  class Report
    # Bump only on a breaking change to the serialized shape.
    SCHEMA_VERSION = 1

    attr_reader :root, :git_ref, :generated_at, :churn_window, :churn_since, :hotspots

    # @param root [String] absolute path the analysis was rooted at
    # @param hotspots [Array<Hotspot>] ranked, highest score first
    # @param git_ref [String, nil] HEAD sha when run inside a repo
    # @param generated_at [String, nil] ISO8601 timestamp
    # @param churn_window [String, nil] human description of the churn window
    # @param churn_since [String, nil] the resolved --since boundary (ISO8601 date)
    def initialize(root:, hotspots:, git_ref: nil, generated_at: nil, churn_window: nil, churn_since: nil)
      @root = root
      @hotspots = hotspots
      @git_ref = git_ref
      @generated_at = generated_at
      @churn_window = churn_window
      @churn_since = churn_since
    end

    def to_h
      {
        schema_version: SCHEMA_VERSION,
        tool: {name: "moult", version: Moult::VERSION},
        analysis: {
          root: root,
          git_ref: git_ref,
          generated_at: generated_at,
          churn: {window: churn_window, since: churn_since}
        },
        hotspots: hotspots.map(&:to_h)
      }
    end

    # One ranked file.
    class Hotspot
      attr_reader :path, :score, :complexity, :churn, :methods, :confidence, :category

      # @param path [String] path relative to the analysis root
      # @param score [Float] complexity x churn
      # @param complexity [Float] aggregate ABC for the file
      # @param churn [Integer] commits touching the file in the window
      # @param methods [Array<Method>] worst methods, highest ABC first
      def initialize(path:, score:, complexity:, churn:, methods:, confidence: nil, category: nil)
        @path = path
        @score = score
        @complexity = complexity
        @churn = churn
        @methods = methods
        @confidence = confidence
        @category = category
      end

      # The single worst method in the file, for table drill-down.
      def worst_method
        methods.first
      end

      def to_h
        {
          path: path,
          score: score,
          complexity: complexity,
          churn: churn,
          confidence: confidence,
          category: category,
          methods: methods.map(&:to_h)
        }
      end
    end

    # One method definition with its complexity.
    class Method
      attr_reader :symbol_id, :name, :span, :abc, :confidence, :category

      # @param symbol_id [String] stable join key: "<path>:<start_line>:<fqname>"
      # @param name [String] lexical fully-qualified name (Class#method / Class.method)
      # @param span [Span] definition source range
      # @param abc [Float] flog-style weighted ABC score
      def initialize(symbol_id:, name:, span:, abc:, confidence: nil, category: nil)
        @symbol_id = symbol_id
        @name = name
        @span = span
        @abc = abc
        @confidence = confidence
        @category = category
      end

      def to_h
        {
          symbol_id: symbol_id,
          name: name,
          span: span.to_h,
          abc: abc,
          confidence: confidence,
          category: category
        }
      end
    end
  end
end
