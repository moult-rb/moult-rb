# frozen_string_literal: true

require "optparse"
require "time"

module Moult
  class CLI
    # `moult health [PATH]` — a composite, auditable health score aggregated from
    # the other analyses. Thin layer: parse options, build the index + Rails
    # awareness (+ optional coverage), drive {Health.build_report}, hand the
    # {HealthReport} to a formatter. Report-only: exit 0 on success (even on a low
    # score — the PR gate is Phase 4), non-zero only on a hard error.
    class HealthCommand
      VALID_COVERAGE_FORMATS = %i[auto simplecov coverage].freeze

      # @return [Integer] process exit status
      def run(argv)
        options = parse(argv)
        return puts_help(options) if options[:help]

        root = File.expand_path(options[:path])
        unless File.exist?(root)
          warn "moult: no such file or directory: #{options[:path]}"
          return 1
        end

        report = analyze(root, options)
        puts render(report, options)
        0
      rescue OptionParser::ParseError => e
        warn "moult: #{e.message}"
        1
      rescue => e
        warn "moult: #{e.message}"
        1
      end

      private

      def parse(argv)
        options = {format: :table, rails: true, quiet: false,
                   coverage: nil, coverage_format: :auto, since: Churn::DEFAULT_SINCE}
        @parser = OptionParser.new do |o|
          o.banner = "Usage: moult health [PATH] [options]"
          o.separator ""
          o.separator "Aggregates complexity, dead code, duplication and (optionally) runtime"
          o.separator "coverage into one confidence-graded health score. Report-only."
          o.separator ""
          o.separator "Options:"
          o.on("--format FORMAT", [:table, :json], "Output format: table (default) or json") { |v| options[:format] = v }
          o.on("--coverage PATH", "Merge a local coverage file (SimpleCov .resultset.json or a Coverage.result dump)") { |v| options[:coverage] = v }
          o.on("--coverage-format FORMAT", VALID_COVERAGE_FORMATS, "Coverage format: auto (default), simplecov, or coverage") { |v| options[:coverage_format] = v }
          o.on("--[no-]rails", "Apply Rails entrypoint awareness to dead code (default on)") { |v| options[:rails] = v }
          o.on("--since DATE", "Churn window start for complexity, any git --since value (default '#{Churn::DEFAULT_SINCE}')") { |v| options[:since] = v }
          o.on("--quiet", "Suppress informational notes on stderr") { options[:quiet] = true }
          o.on("-h", "--help", "Show this message") { options[:help] = true }
        end
        @parser.permute!(argv)
        options[:path] = argv.shift || "."
        options
      end

      def puts_help(_options)
        puts @parser
        0
      end

      def analyze(root, options)
        root_dir, files = Support.discover(root)
        index = Index.build(root: root_dir, paths: files)
        rails = Support.build_rails(root_dir, files, enabled: options[:rails])
        coverage = load_coverage(root_dir, options)
        merged = coverage ? ", coverage merged" : ""
        note(options, "scored #{files.size} files; index #{index.resolved? ? "resolved" : "unresolved"}#{merged}.")

        Health.build_report(
          root: root_dir,
          files: files,
          index: index,
          rails: rails,
          coverage: coverage,
          since: options[:since],
          git_ref: Git.head_ref(root_dir),
          generated_at: Time.now.utc.iso8601,
          churn_window: window_label(options[:since]),
          churn_since: explicit_since(options[:since])
        )
      end

      def load_coverage(root_dir, options)
        return nil unless options[:coverage]
        dataset = Coverage.load(options[:coverage], root: root_dir, format: options[:coverage_format])
        note(options, "merged #{dataset.entries.size} covered files (#{dataset.source.backend}); #{dataset.unmatched_count} outside root ignored.")
        dataset
      end

      def render(report, options)
        case options[:format]
        when :json then Formatters::HealthJson.render(report)
        else Formatters::HealthTable.render(report)
        end
      end

      def window_label(since)
        (since == Churn::DEFAULT_SINCE) ? "last 12 months" : "since #{since}"
      end

      def explicit_since(since)
        (since == Churn::DEFAULT_SINCE) ? nil : since
      end

      def note(options, message)
        warn "moult: #{message}" unless options[:quiet]
      end
    end
  end
end
