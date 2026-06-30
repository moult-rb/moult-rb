# frozen_string_literal: true

module Moult
  module Coverage
    # The line->symbol resolver: turns line-keyed coverage into a per-symbol
    # runtime classification. This is the one genuinely novel
    # component, so its rules are precise and fixture-pinned — drift is a bug,
    # exactly like the ABC metric.
    #
    # For a method definition spanning +span.start_line..span.end_line+ in a
    # tracked file, it inspects the *body* lines and returns:
    #
    # * +:hot+       — at least one executable body line was executed
    # * +:cold+      — the file is tracked, body has executable lines, none ran
    # * +:untracked+ — no usable signal (see below)
    #
    # The defining rule is that the +def+ signature line is EXCLUDED: stdlib
    # +Coverage+ counts it at definition (load) time, not per call, so counting
    # it would mark every loaded method hot. Only the body reflects real calls.
    module Resolver
      module_function

      # @param dataset [Dataset]
      # @param path [String] root-relative path (a symbol_id component)
      # @param span [Span] 1-based definition span
      # @param kind [Symbol] :method or :constant
      # @return [Symbol] :hot, :cold, or :untracked
      def classify(dataset, path:, span:, kind:)
        # A constant's only line is its assignment, executed at load regardless
        # of whether the constant is ever read — so it carries no runtime signal.
        return :untracked unless kind == :method
        lines = dataset.entries[path]
        return :untracked unless lines

        executable = body_values(lines, span)
        # No executable body line to judge: one-line methods (def f = x), empty
        # methods, abstract stubs. Their only line is the def line (load-time
        # coverage), so they are genuinely unclassifiable in :lines mode.
        return :untracked if executable.empty?

        executable.any?(&:positive?) ? :hot : :cold
      end

      # Coverage values for the executable (non-nil) body lines, excluding the
      # +def+ signature line at +span.start_line+. The +end+ line and blanks are
      # nil and so fall out naturally.
      # @return [Array<Integer>]
      def body_values(lines, span)
        first = span.start_line + 1
        last = span.end_line
        return [] if first > last
        (first..last).filter_map { |line| lines[line - 1] }
      end
    end
  end
end
