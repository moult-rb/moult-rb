# frozen_string_literal: true

require_relative "span"

module Moult
  # The per-finding confidence model — one of Moult's two protected APIs (the
  # other being the JSON output contract). It answers a single, deliberately
  # humble question: *how likely is this definition to actually be dead?* It
  # never asserts certain death (Moult's core principle); the highest a finding
  # can score is still a confidence, and every contributing factor is recorded
  # as a {Reason} so the judgement is auditable.
  #
  # {score} is a pure function of a {Context} of already-gathered facts: no IO,
  # no rubydex, no Rails detection happens here. That keeps it trivially
  # unit-testable and lets each {Rules::Rule} be exercised in isolation. The fact
  # gathering lives in {DeadCode}; the conventions live in {RailsConventions}.
  module Confidence
    CATEGORY = "dead_code"

    # Base likelihood before any rule fires, keyed by [kind, visibility]. A
    # private method with no caller is the strongest candidate (nothing outside
    # its class can reach it); public symbols are weakest because they are the
    # natural API surface and the place metaprogramming/Rails reach in.
    BASE = {
      [:method, :private] => 0.75,
      [:method, :protected] => 0.6,
      [:method, :public] => 0.4,
      [:constant, :private] => 0.6,
      [:constant, :public] => 0.5
    }.freeze
    DEFAULT_BASE = 0.45

    # The facts a finding is scored from. Assembled by {DeadCode#gather_context}.
    Context = Struct.new(
      :symbol_id, :kind, :name, :span, :path,
      :visibility, :reference_count, :test_only,
      :rails_signals,      # Array<RailsConventions::Signal>
      :dynamic_dispatch,   # Boolean: metaprogramming present in the owning file
      :override_of,        # String, nil: ancestor whose method this overrides
      :deprecated,         # Boolean
      :index_resolved,
      :runtime,            # Symbol, nil: :hot/:cold/:untracked from coverage (Phase 3)
      :override_live,      # Boolean, nil: the overridden ancestor type has a production reference; nil = ancestor not indexed (unknown)
      :hierarchy_referenced # Boolean, nil: the owner type or a descendant has a production reference; nil = owner not indexed (unknown)
    )

    # One auditable contribution to a finding's confidence.
    Reason = Struct.new(:rule, :delta, :detail) do
      def to_h
        {rule: rule.to_s, delta: delta, detail: detail}
      end
    end

    # A confidence-graded dead-code candidate. Carries its reasons so no claim
    # is ever made without a recorded justification.
    Finding = Struct.new(
      :symbol_id, :kind, :name, :span, :path, :confidence, :category, :reasons, :runtime
    ) do
      def to_h
        {
          symbol_id: symbol_id,
          kind: kind.to_s,
          name: name,
          span: span.to_h,
          confidence: confidence,
          category: category,
          runtime: runtime&.to_s,
          reasons: reasons.map(&:to_h)
        }
      end
    end

    module_function

    # @param ctx [Context]
    # @param rules [Array<Rules::Rule>] injectable for isolated testing
    # @return [Finding]
    def score(ctx, rules: Rules::DEFAULT_RULES)
      base = BASE.fetch([ctx.kind, ctx.visibility], DEFAULT_BASE)
      reasons = [Reason.new(rule: :base_score, delta: base, detail: "base for #{ctx.kind}/#{ctx.visibility}")]
      caps = []

      rules.each do |rule|
        next unless rule.applies?(ctx)
        reasons << Reason.new(rule: rule.name, delta: rule.delta, detail: rule.detail_for(ctx))
        caps << rule.cap if rule.cap
      end

      raw = reasons.sum(&:delta)
      bounded = caps.empty? ? raw : [raw, caps.min].min
      confidence = bounded.clamp(0.0, 1.0).round(2)

      Finding.new(
        symbol_id: ctx.symbol_id,
        kind: ctx.kind,
        name: ctx.name,
        span: ctx.span,
        path: ctx.path,
        confidence: confidence,
        category: CATEGORY,
        reasons: reasons,
        runtime: ctx.runtime
      )
    end
  end
end

require_relative "confidence/rules"
