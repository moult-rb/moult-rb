# frozen_string_literal: true

module Moult
  module Flags
    # The per-finding model for feature flags — this slice's realisation of Moult's
    # protected per-finding API. Like a packwerk boundary violation (see
    # {Boundaries::Severity}), a flag *reference* is a recorded FACT, not a
    # probabilistic candidate: the scanner saw the call site. So we never manufacture
    # a fake confidence (the finding's +confidence+ is null); the per-finding signal
    # is a categorical CLASSIFICATION instead — the flag's value_type, how many times
    # it is referenced, and the literal default value(s) observed.
    #
    # The genuinely confidence-graded judgement — *staleness* (is this flag dead /
    # obsolete?) — needs a live OpenFeature provider to know which keys still exist,
    # and is deferred (like the Coverband/Flipper live stores). So the humility
    # invariant holds in this register too: a static scan can never prove a flag is
    # unused (it may be referenced dynamically, via provider config, or from outside
    # the codebase), and nothing here says it is.
    #
    # {classify} is a pure function of the observed signals — no IO, no Prism nodes —
    # so it is pinned against hand-built inputs exactly like {ABC}, the coverage
    # {Resolver}, the duplication {Confidence} model, and {Boundaries::Severity}.
    # Drift is a bug.
    module Classification
      CATEGORY = "feature_flag"

      # The value-type classification. boolean/string/number/object are read from the
      # fetch_<type>_* method; +unknown+ is reserved for a flag referenced with more
      # than one type (an ambiguity we record rather than resolve).
      VALUE_TYPES = %w[boolean string number object unknown].freeze
      MIXED = "unknown"

      # One auditable note behind a classification. Mirrors the shared rule/detail
      # reason shape; a classification is categorical (not a delta-sum) so it carries
      # no +delta+, like {Boundaries::Severity::Reason}. Kept local so the flags slice
      # does not couple to the dead-code/duplication Reason structs.
      Reason = Struct.new(:rule, :detail) do
        def to_h
          {rule: rule.to_s, detail: detail}
        end
      end

      # The classified result: the resolved value_type, the reference count, the
      # distinct literal defaults, and the reasons behind them.
      Assessment = Struct.new(:value_type, :reference_count, :default_values, :reasons)

      module_function

      # @param value_types [Array<String>] one observed value_type per call site
      # @param default_values [Array<String, nil>] one observed literal default per
      #   call site (nil where the default was not a literal)
      # @return [Assessment]
      def classify(value_types:, default_values:)
        observed = value_types.uniq.sort
        value_type = (observed.size == 1) ? observed.first : MIXED
        reference_count = value_types.size
        defaults = default_values.compact.uniq.sort

        reasons = [type_reason(value_type, observed, reference_count)]
        reasons << Reason.new(rule: :reference_count, detail: "referenced at #{pluralize(reference_count, "call site")}")
        reasons << Reason.new(rule: :default_values, detail: "observed default value(s): #{defaults.join(", ")}") unless defaults.empty?

        Assessment.new(value_type: value_type, reference_count: reference_count, default_values: defaults, reasons: reasons)
      end

      def type_reason(value_type, observed, reference_count)
        if value_type == MIXED
          Reason.new(rule: :mixed_value_types, detail: "referenced with differing value types (#{observed.join(", ")}); the flag type is ambiguous")
        else
          Reason.new(rule: :"#{value_type}_flag", detail: "evaluated as a #{value_type} flag across #{pluralize(reference_count, "reference")}")
        end
      end

      def pluralize(count, noun)
        "#{count} #{noun}#{"s" unless count == 1}"
      end
    end
  end
end
