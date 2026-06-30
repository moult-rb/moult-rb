# frozen_string_literal: true

require "optparse"
require "time"

module Moult
  class CLI
    # `moult flags [PATH]` — catalogue OpenFeature feature-flag references found by a
    # static Prism scan. Thin layer: parse options, discover files, drive the
    # library, hand the {FlagsReport} to a formatter. Report-only: exit 0 on success
    # (including when no flags are found), non-zero only on error.
    class FlagsCommand
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

      VALID_PROVIDER_FORMATS = %i[auto flagd].freeze

      def parse(argv)
        options = {format: :table, quiet: false, provider: nil, provider_format: :auto}
        @parser = OptionParser.new do |o|
          o.banner = "Usage: moult flags [PATH] [options]"
          o.separator ""
          o.separator "Options:"
          o.on("--format FORMAT", [:table, :json], "Output format: table (default) or json") { |v| options[:format] = v }
          o.on("--provider PATH", "Merge a local OpenFeature provider snapshot (a flagd flag-definition export) for confidence-graded staleness candidates") { |v| options[:provider] = v }
          o.on("--provider-format FORMAT", VALID_PROVIDER_FORMATS, "Provider snapshot format: auto (default) or flagd") { |v| options[:provider_format] = v }
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
        snapshot = load_snapshot(options)
        report = Flags.build_report(
          root: root_dir,
          files: files,
          git_ref: Git.head_ref(root_dir),
          generated_at: Time.now.utc.iso8601,
          snapshot: snapshot
        )
        note(options, "scanned #{files.size} files for OpenFeature flag references: #{report.summary[:flags]} flags.")
        report
      end

      def load_snapshot(options)
        return nil unless options[:provider]
        set = Flags::Snapshot.load(options[:provider], format: options[:provider_format])
        note(options, "merged provider snapshot (#{set.source.backend}): #{set.states.size} flags known to the provider.")
        set
      end

      def render(report, options)
        case options[:format]
        when :json then Formatters::FlagsJson.render(report)
        else Formatters::FlagsTable.render(report)
        end
      end

      def note(options, message)
        warn "moult: #{message}" unless options[:quiet]
      end
    end
  end
end
