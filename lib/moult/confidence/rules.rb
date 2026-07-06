# frozen_string_literal: true

module Moult
  module Confidence
    # The named, ordered adjusters {Confidence.score} applies on top of the base
    # score. Each is a small value object so a single rule can be tested in
    # isolation and the set can be extended without touching the scorer.
    #
    # Direction is encoded in +delta+: positive raises confidence-of-death,
    # negative lowers it. A rule may instead (or also) impose a +cap+ — an upper
    # bound on the final confidence — used when a factor means "we genuinely
    # cannot be sure", e.g. an unresolved index. No rule ever removes a finding:
    # consistent with "never assert certain death", uncertainty *lowers*
    # confidence and records a reason, it never hides the candidate.
    module Rules
      # @!attribute applies [Proc] ctx -> Boolean
      # @!attribute delta   [Float] signed adjustment when it applies
      # @!attribute cap     [Float, nil] optional upper bound on final confidence
      # @!attribute detail  [String, Proc] human-readable reason (Proc gets ctx)
      Rule = Struct.new(:name, :applies, :delta, :cap, :detail) do
        def applies?(ctx)
          applies.call(ctx)
        end

        def detail_for(ctx)
          detail.respond_to?(:call) ? detail.call(ctx) : detail
        end
      end

      DEFAULT_RULES = [
        Rule.new(
          name: :no_references,
          applies: ->(c) { c.reference_count.to_i.zero? },
          delta: 0.0,
          detail: "no resolvable references found"
        ),
        Rule.new(
          name: :has_test_only_references,
          applies: ->(c) { c.test_only },
          delta: -0.2,
          detail: "only referenced from test/spec files"
        ),
        Rule.new(
          name: :rails_entrypoint,
          applies: ->(c) { !Array(c.rails_signals).empty? },
          delta: -0.5,
          detail: ->(c) { "Rails framework entrypoint: #{Array(c.rails_signals).map(&:detail).join("; ")}" }
        ),
        Rule.new(
          name: :dynamic_dispatch_present,
          applies: ->(c) { c.dynamic_dispatch },
          delta: -0.35,
          detail: "dynamic dispatch (send/define_method/method_missing/const_get/eval) present in file"
        ),
        # Constructors are invoked implicitly by `.new`, not by a call to
        # `initialize`, so the index never records a reference. Universal Ruby
        # (not Rails); kept narrow to this one near-certain implicit entrypoint.
        Rule.new(
          name: :implicit_constructor,
          applies: ->(c) { c.kind == :method && c.name.to_s.end_with?("#initialize") },
          delta: -0.4,
          detail: "constructor invoked implicitly via .new"
        ),
        # A method that overrides/implements an ancestor's method is reachable
        # through that ancestor's interface (polymorphic dispatch) even with no
        # by-name call site — the same signal a typed tool gets free from its
        # inheritance graph. Covers framework hooks (visitor #visit_*, job
        # #perform) when the ancestor's source is indexed. Fires when the
        # ancestor type is live or of unknown liveness (Object, gems:
        # conservative); a provably unreferenced ancestor downgrades to the
        # weaker rule below instead.
        Rule.new(
          name: :overrides_ancestor,
          applies: ->(c) { c.override_of && c.override_live != false },
          delta: -0.4,
          detail: ->(c) { "overrides #{c.override_of} (reachable via that interface)" }
        ),
        # The overridden ancestor type itself has no production reference: the
        # polymorphic path exists syntactically, but nothing names the type, so
        # the hierarchy is likely dead together. A mild brake, not the full
        # -0.4 — the reachability is mostly moot.
        Rule.new(
          name: :overrides_unreferenced_ancestor,
          applies: ->(c) { c.override_of && c.override_live == false },
          delta: -0.1,
          detail: ->(c) { "overrides #{c.override_of}, but that ancestor type is itself unreferenced outside tests" }
        ),
        # Neither the owner type nor any of its descendants is referenced in
        # production: no constant path reaches the method's receiver at all.
        # Modest raise — dynamic-dispatch and Rails rescue rules must still be
        # able to counteract it.
        Rule.new(
          name: :unreferenced_hierarchy,
          applies: ->(c) { c.hierarchy_referenced == false },
          delta: 0.1,
          detail: "no reference to the owner type or any of its descendants outside tests"
        ),
        Rule.new(
          name: :private_unused,
          applies: ->(c) { c.kind == :method && c.visibility == :private && c.reference_count.to_i.zero? },
          delta: 0.1,
          detail: "private method with no caller in the codebase"
        ),
        Rule.new(
          name: :public_api,
          applies: ->(c) { c.kind == :method && c.visibility == :public },
          delta: -0.1,
          detail: "public method may be an external API entrypoint"
        ),
        Rule.new(
          name: :deprecated_marked,
          applies: ->(c) { c.deprecated },
          delta: 0.1,
          detail: "marked deprecated"
        ),
        Rule.new(
          name: :index_unresolved,
          applies: ->(c) { c.index_resolved == false },
          delta: 0.0,
          cap: 0.5,
          detail: "index did not fully resolve; confidence capped"
        ),
        # Phase 3 runtime evidence. Applied last so it is the headline reason and,
        # for the rescue case, caps over every static signal. Methods only — a
        # constant's line runs at load regardless of use, so the resolver returns
        # :untracked for constants and neither rule fires.
        #
        # runtime-cold corroborates a static candidate: the body never executed in
        # the supplied run. Additive (not a cap) — coverage can be incomplete or
        # stale (stale-detection deferred), so it raises confidence, never asserts.
        Rule.new(
          name: :runtime_cold,
          applies: ->(c) { c.runtime == :cold },
          delta: 0.2,
          detail: "never executed in the supplied coverage run (runtime-cold corroborates)"
        ),
        # runtime-hot overrides: the symbol executed despite no resolvable static
        # reference — the false positive static analysis missed (send / dynamic
        # dispatch / metaprogramming). The cap drives it below default confidence
        # gates while leaving a sliver, since coverage may be stale/incomplete.
        Rule.new(
          name: :runtime_hot,
          applies: ->(c) { c.runtime == :hot },
          delta: -0.6,
          cap: 0.1,
          detail: "executed at runtime (coverage) despite no static reference; rescued"
        )
      ].freeze
    end
  end
end
