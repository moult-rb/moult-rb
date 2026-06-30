# frozen_string_literal: true

require "optparse"
require "time"

module Moult
  class CLI
    # `moult hotspots [PATH]` — rank files by complexity x churn. Thin layer:
    # parse options, drive the library, hand the {Report} to a formatter.
    # Report-only: exit 0 on success, non-zero only on error.
    class HotspotsCommand
      DEFAULT_LIMIT = 20

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
        options = {format: :table, limit: DEFAULT_LIMIT, since: Churn::DEFAULT_SINCE, quiet: false}
        @parser = OptionParser.new do |o|
          o.banner = "Usage: moult hotspots [PATH] [options]"
          o.separator ""
          o.separator "Options:"
          o.on("--format FORMAT", [:table, :json], "Output format: table (default) or json") { |v| options[:format] = v }
          o.on("--limit N", Integer, "Show top N hotspots (default #{DEFAULT_LIMIT}; 0 for all)") { |v| options[:limit] = v }
          o.on("--since DATE", "Churn window start, any git --since value (default '#{Churn::DEFAULT_SINCE}')") { |v| options[:since] = v }
          o.on("--quiet", "Suppress informational notes on stderr") { options[:quiet] = true }
          o.on("-h", "--help", "Show this message") { options[:help] = true }
        end
        # permute! processes options regardless of position, so `PATH` may come
        # before or after flags; remaining non-options are left in argv.
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

        unless Git.repo?(root_dir)
          note(options, "#{root_dir} is not a git repository; churn is 0 for all files.")
        end

        Scoring.build_report(
          root: root_dir,
          files: files,
          churn: Churn.collect(root: root_dir, since: options[:since]),
          git_ref: Git.head_ref(root_dir),
          generated_at: Time.now.utc.iso8601,
          churn_window: window_label(options[:since]),
          churn_since: explicit_since(options[:since])
        )
      end

      def render(report, options)
        limit = (options[:limit] && options[:limit] > 0) ? options[:limit] : nil
        case options[:format]
        when :json then Formatters::Json.render(report, limit: limit)
        else Formatters::Table.render(report, limit: limit)
        end
      end

      def window_label(since)
        (since == Churn::DEFAULT_SINCE) ? "last 12 months" : "since #{since}"
      end

      # Only surface a concrete --since boundary when the user gave a fixed one;
      # the relative default ("12 months ago") has no stable date.
      def explicit_since(since)
        (since == Churn::DEFAULT_SINCE) ? nil : since
      end

      def note(options, message)
        warn "moult: #{message}" unless options[:quiet]
      end
    end
  end
end
