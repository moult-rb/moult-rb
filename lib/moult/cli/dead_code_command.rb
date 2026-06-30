# frozen_string_literal: true

require "optparse"
require "time"

module Moult
  class CLI
    # `moult deadcode [PATH]` — list confidence-graded dead-code candidates.
    # Thin layer: parse options, build the index + Rails awareness, drive the
    # library, hand the {DeadCodeReport} to a formatter. Report-only: exit 0 on
    # success, non-zero only on error.
    class DeadCodeCommand
      DEFAULT_MIN_CONFIDENCE = 0.0

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

      VALID_COVERAGE_FORMATS = %i[auto simplecov coverage].freeze

      def parse(argv)
        options = {format: :table, min_confidence: DEFAULT_MIN_CONFIDENCE, rails: true, quiet: false,
                   coverage: nil, coverage_format: :auto}
        @parser = OptionParser.new do |o|
          o.banner = "Usage: moult deadcode [PATH] [options]"
          o.separator ""
          o.separator "Options:"
          o.on("--format FORMAT", [:table, :json], "Output format: table (default) or json") { |v| options[:format] = v }
          o.on("--min-confidence N", Float, "Hide findings below this confidence 0..1 (default #{DEFAULT_MIN_CONFIDENCE})") { |v| options[:min_confidence] = v }
          o.on("--[no-]rails", "Apply Rails entrypoint awareness (default on)") { |v| options[:rails] = v }
          o.on("--coverage PATH", "Merge a local coverage file as runtime evidence (SimpleCov .resultset.json or a Coverage.result dump)") { |v| options[:coverage] = v }
          o.on("--coverage-format FORMAT", VALID_COVERAGE_FORMATS, "Coverage format: auto (default), simplecov, or coverage") { |v| options[:coverage_format] = v }
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
        note(options, "analysed #{files.size} files; index #{index.resolved? ? "resolved" : "unresolved"}.")
        unless rails.rails?
          note(options, "not a Rails app (or --no-rails); framework entrypoint awareness is off.")
        end

        DeadCode.build_report(
          root: root_dir,
          files: files,
          index: index,
          rails: rails,
          min_confidence: options[:min_confidence],
          git_ref: Git.head_ref(root_dir),
          generated_at: Time.now.utc.iso8601,
          backend_version: rubydex_version,
          coverage: coverage
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
        when :json then Formatters::DeadCodeJson.render(report)
        else Formatters::DeadCodeTable.render(report)
        end
      end

      def rubydex_version
        defined?(Rubydex::VERSION) ? Rubydex::VERSION : nil
      end

      def note(options, message)
        warn "moult: #{message}" unless options[:quiet]
      end
    end
  end
end
