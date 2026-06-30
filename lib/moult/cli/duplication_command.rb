# frozen_string_literal: true

require "optparse"
require "time"

module Moult
  class CLI
    # `moult duplication [PATH]` — list confidence-graded structural-clone groups.
    # Thin layer: parse options, discover files, drive the library, hand the
    # {DuplicationReport} to a formatter. Report-only: exit 0 on success, non-zero
    # only on error.
    class DuplicationCommand
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

      def parse(argv)
        options = {format: :table, min_mass: Clones::DEFAULT_MIN_MASS, fuzzy: false,
                   min_confidence: DEFAULT_MIN_CONFIDENCE, quiet: false}
        @parser = OptionParser.new do |o|
          o.banner = "Usage: moult duplication [PATH] [options]"
          o.separator ""
          o.separator "Options:"
          o.on("--format FORMAT", [:table, :json], "Output format: table (default) or json") { |v| options[:format] = v }
          o.on("--min-mass N", Integer, "Ignore clones below this structural mass (default #{Clones::DEFAULT_MIN_MASS})") { |v| options[:min_mass] = v }
          o.on("--[no-]fuzzy", "Also report near-matches, not just structural-equivalents (default off)") { |v| options[:fuzzy] = v }
          o.on("--min-confidence N", Float, "Hide findings below this confidence 0..1 (default #{DEFAULT_MIN_CONFIDENCE})") { |v| options[:min_confidence] = v }
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
        mode = options[:fuzzy] ? ", fuzzy" : ""
        note(options, "scanned #{files.size} files for duplication (flay, min-mass #{options[:min_mass]}#{mode}).")

        Duplication.build_report(
          root: root_dir,
          files: files,
          min_mass: options[:min_mass],
          fuzzy: options[:fuzzy],
          min_confidence: options[:min_confidence],
          git_ref: Git.head_ref(root_dir),
          generated_at: Time.now.utc.iso8601
        )
      end

      def render(report, options)
        case options[:format]
        when :json then Formatters::DuplicationJson.render(report)
        else Formatters::DuplicationTable.render(report)
        end
      end

      def note(options, message)
        warn "moult: #{message}" unless options[:quiet]
      end
    end
  end
end
