# frozen_string_literal: true

require "optparse"
require "time"

module Moult
  class CLI
    # `moult boundaries [PATH]` — list recorded architecture-boundary violations from
    # the project's packwerk artifacts, classified by severity. Thin layer: parse
    # options, drive the library, hand the {BoundariesReport} to a formatter.
    # Report-only: exit 0 on success (including when the project is not
    # packwerk-configured), non-zero only on error.
    class BoundariesCommand
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
        options = {format: :table, min_severity: nil, quiet: false}
        @parser = OptionParser.new do |o|
          o.banner = "Usage: moult boundaries [PATH] [options]"
          o.separator ""
          o.separator "Options:"
          o.on("--format FORMAT", [:table, :json], "Output format: table (default) or json") { |v| options[:format] = v }
          o.on("--min-severity SEV", Boundaries::Severity::SCALE, "Hide findings below this severity: low, medium, high") { |v| options[:min_severity] = v }
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
        report = Boundaries.build_report(
          root: root_dir,
          min_severity: options[:min_severity],
          git_ref: Git.head_ref(root_dir),
          generated_at: Time.now.utc.iso8601
        )
        note(options, report.configured ? "read packwerk artifacts: #{report.summary[:findings]} violation groups." : "no packwerk.yml found; not a packwerk project.")
        report
      end

      def render(report, options)
        case options[:format]
        when :json then Formatters::BoundariesJson.render(report)
        else Formatters::BoundariesTable.render(report)
        end
      end

      def note(options, message)
        warn "moult: #{message}" unless options[:quiet]
      end
    end
  end
end
