# frozen_string_literal: true

require "optparse"
require "time"

module Moult
  class CLI
    # `moult cycles [PATH]` — list circular file dependencies over resolved
    # constant references. Thin layer: parse options, build the index, drive
    # the library, hand the {CyclesReport} to a formatter. Report-only: exit 0
    # on success, non-zero only on error.
    class CyclesCommand
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
        options = {format: :table, quiet: false}
        @parser = OptionParser.new do |o|
          o.banner = "Usage: moult cycles [PATH] [options]"
          o.separator ""
          o.separator "Options:"
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
        root_dir, files = Support.discover(root)
        index = Index.build(root: root_dir, paths: files)
        edges = index.file_edges
        note(options, "analysed #{files.size} files; #{edges.size} constant-resolved dependency edges.")

        Cycles.build_report(
          root: root_dir,
          edges: edges,
          git_ref: Git.head_ref(root_dir),
          generated_at: Time.now.utc.iso8601,
          backend_version: rubydex_version,
          resolved: index.resolved?,
          diagnostics: index.diagnostics
        )
      end

      def render(report, options)
        case options[:format]
        when :json then Formatters::CyclesJson.render(report)
        else Formatters::CyclesTable.render(report)
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
