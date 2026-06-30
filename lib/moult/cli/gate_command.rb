# frozen_string_literal: true

require "optparse"
require "time"

module Moult
  class CLI
    # `moult gate [PATH]` — the diff-aware PR risk gate. Thin layer: parse options,
    # build the index + Rails awareness, resolve the policy (defaults, overridable
    # via .moult.yml), drive {Gate.build_report}, hand the {GateReport} to a
    # formatter. Holds NO policy logic.
    #
    # Exit code (the one command in Moult that renders a verdict, so it is the one
    # exception to the repo-wide "1 = error" convention):
    #   0 = gate passed
    #   1 = gate failed (policy violated)
    #   2 = tool error (bad option, missing path, unresolvable diff, …)
    class GateCommand
      PASS = 0
      FAIL = 1
      ERROR = 2

      # @return [Integer] process exit status
      def run(argv)
        options = parse(argv)
        return puts_help if options[:help]

        execute(options)
      rescue OptionParser::ParseError, Moult::Error => e
        warn "moult: #{e.message}"
        ERROR
      rescue => e
        warn "moult: #{e.message}"
        ERROR
      end

      private

      def execute(options)
        root = File.expand_path(options[:path])
        unless File.exist?(root)
          warn "moult: no such file or directory: #{options[:path]}"
          return ERROR
        end

        report = analyze(root, options)
        puts render(report, options)
        (report.verdict == "pass") ? PASS : FAIL
      end

      def parse(argv)
        options = {format: :table, base: "origin/main", scope: :diff,
                   config: nil, rails: true, quiet: false}
        @parser = OptionParser.new do |o|
          o.banner = "Usage: moult gate [PATH] [options]"
          o.separator ""
          o.separator "Diff-aware PR risk gate: scopes the analyses to the code changed since a"
          o.separator "base ref, applies an explicit policy, and exits non-zero when violated."
          o.separator ""
          o.separator "Options:"
          o.on("--base REF", "Base ref for the diff (default 'origin/main'); gate uses merge-base(REF, HEAD)") { |v| options[:base] = v }
          o.on("--scope SCOPE", [:diff, :all], "What to gate: diff (default, new code only) or all (whole codebase)") { |v| options[:scope] = v }
          o.on("--format FORMAT", [:table, :json, :github, :sarif], "Output: table (default), json, github (annotations), or sarif") { |v| options[:format] = v }
          o.on("--config FILE", "Policy overrides file (default: .moult.yml at the root, if present)") { |v| options[:config] = v }
          o.on("--[no-]rails", "Apply Rails entrypoint awareness to dead code (default on)") { |v| options[:rails] = v }
          o.on("--quiet", "Suppress informational notes on stderr") { options[:quiet] = true }
          o.on("-h", "--help", "Show this message") { options[:help] = true }
        end
        @parser.permute!(argv)
        options[:path] = argv.shift || "."
        options
      end

      def puts_help
        puts @parser
        PASS
      end

      def analyze(root, options)
        root_dir, files = Support.discover(root)
        index = Index.build(root: root_dir, paths: files)
        rails = Support.build_rails(root_dir, files, enabled: options[:rails])
        policy = Gate::Config.policy_for(root: root_dir, config_path: options[:config])
        note(options, "gating #{files.size} files (scope: #{options[:scope]}, policy: #{policy.source}); index #{index.resolved? ? "resolved" : "unresolved"}.")

        Gate.build_report(
          root: root_dir,
          files: files,
          index: index,
          rails: rails,
          base_ref: options[:base],
          scope: options[:scope],
          policy: policy,
          git_ref: Git.head_ref(root_dir),
          generated_at: Time.now.utc.iso8601
        )
      end

      def render(report, options)
        case options[:format]
        when :json then Formatters::GateJson.render(report)
        when :github then Formatters::GateGithub.render(report)
        when :sarif then Formatters::GateSarif.render(report)
        else Formatters::GateTable.render(report)
        end
      end

      def note(options, message)
        warn "moult: #{message}" unless options[:quiet]
      end
    end
  end
end
