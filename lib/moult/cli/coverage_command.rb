# frozen_string_literal: true

require "optparse"
require "time"

module Moult
  class CLI
    # `moult coverage [PATH] --coverage FILE` — a per-symbol hot/cold/untracked
    # map resolved from a local coverage file. Thin layer: parse options, build
    # the index, load the dataset, drive {CoverageReport.build}, format. The map
    # is diagnostic; it makes no dead-code claim (see `moult deadcode --coverage`
    # for the confidence merge).
    class CoverageCommand
      VALID_FORMATS = %i[auto simplecov coverage].freeze

      # @return [Integer] process exit status
      def run(argv)
        options = parse(argv)
        return puts_help(options) if options[:help]

        unless options[:coverage]
          warn "moult: coverage requires --coverage PATH"
          warn @parser
          return 1
        end

        root = File.expand_path(options[:path])
        unless File.exist?(root)
          warn "moult: no such file or directory: #{options[:path]}"
          return 1
        end

        puts render(analyze(root, options), options)
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
        options = {format: :table, coverage: nil, coverage_format: :auto, quiet: false}
        @parser = OptionParser.new do |o|
          o.banner = "Usage: moult coverage [PATH] --coverage FILE [options]"
          o.separator ""
          o.separator "Options:"
          o.on("--coverage PATH", "Local coverage file (SimpleCov .resultset.json or a Coverage.result dump)") { |v| options[:coverage] = v }
          o.on("--coverage-format FORMAT", VALID_FORMATS, "Coverage format: auto (default), simplecov, or coverage") { |v| options[:coverage_format] = v }
          o.on("--format FORMAT", [:table, :json], "Output format: table (default) or json") { |v| options[:format] = v }
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
        root_dir = File.directory?(root) ? root : File.dirname(root)
        files = File.directory?(root) ? Discovery.ruby_files(root) : [root]

        index = Index.build(root: root_dir, paths: files)
        dataset = Coverage.load(options[:coverage], root: root_dir, format: options[:coverage_format])
        note(options, "loaded #{dataset.entries.size} covered files (#{dataset.source.backend}); #{dataset.unmatched_count} outside root ignored.")

        CoverageReport.build(
          index: index,
          coverage: dataset,
          root: root_dir,
          git_ref: Git.head_ref(root_dir),
          generated_at: Time.now.utc.iso8601,
          backend_version: rubydex_version
        )
      end

      def render(report, options)
        case options[:format]
        when :json then Formatters::CoverageJson.render(report)
        else Formatters::CoverageTable.render(report)
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
