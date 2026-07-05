# frozen_string_literal: true

require "optparse"

module Moult
  # Thin command-line layer. Holds no analysis logic of its own: it parses
  # options, delegates to the library, and hands the resulting {Report} to a
  # formatter. Returns a process exit status (0 success, non-zero on error).
  class CLI
    # Subcommand => [require path, command class name]. Lazily required so a single
    # command run never loads every analysis. Adding a slice is one entry here.
    COMMANDS = {
      "hotspots" => ["moult/cli/hotspots_command", :HotspotsCommand],
      "deadcode" => ["moult/cli/dead_code_command", :DeadCodeCommand],
      "coverage" => ["moult/cli/coverage_command", :CoverageCommand],
      "duplication" => ["moult/cli/duplication_command", :DuplicationCommand],
      "cycles" => ["moult/cli/cycles_command", :CyclesCommand],
      "health" => ["moult/cli/health_command", :HealthCommand],
      "boundaries" => ["moult/cli/boundaries_command", :BoundariesCommand],
      "flags" => ["moult/cli/flags_command", :FlagsCommand],
      "gate" => ["moult/cli/gate_command", :GateCommand]
    }.freeze

    # Tiny shared helpers for the command layer, so each command doesn't re-implement
    # the same option plumbing. Lives on the always-loaded dispatcher.
    module Support
      module_function

      # Resolve a PATH argument to its analysis root and the Ruby files under it:
      # a directory analyses its tree, a single file analyses just itself.
      # @return [Array(String, Array<String>)] [root_dir, files]
      def discover(path)
        if File.directory?(path)
          [path, Discovery.ruby_files(path)]
        else
          [File.dirname(path), [path]]
        end
      end

      # Build Rails entrypoint awareness, honouring a command's --[no-]rails option.
      def build_rails(root_dir, files, enabled:)
        return RailsConventions.new(rails: false) unless enabled

        RailsConventions.build(root: root_dir, files: files)
      end
    end

    def self.start(argv)
      new.run(argv)
    end

    # @return [Integer] process exit status
    def run(argv)
      argv = argv.dup

      # Top-level flags that short-circuit before subcommand dispatch.
      case argv.first
      when "--version", "-v"
        puts Moult::VERSION
        return 0
      when nil, "--help", "-h"
        puts usage
        return 0
      end

      dispatch(argv.shift, argv)
    end

    private

    def dispatch(command, argv)
      spec = COMMANDS[command]
      unless spec
        warn "moult: unknown command #{command.inspect}"
        warn usage
        return 1
      end

      require spec[0]
      CLI.const_get(spec[1]).new.run(argv)
    end

    public

    def usage
      <<~USAGE
        moult #{Moult::VERSION} — codebase intelligence for Ruby

        Usage:
          moult hotspots [PATH] [options]     Rank files by complexity x churn
          moult deadcode [PATH] [options]     List confidence-graded dead-code candidates
          moult coverage [PATH] [options]     Map symbols hot/cold/untracked from coverage
          moult duplication [PATH] [options]  List confidence-graded structural-clone groups
          moult cycles [PATH] [options]       List circular file dependencies (constant-resolved)
          moult health [PATH] [options]       Aggregate the analyses into a composite health score
          moult boundaries [PATH] [options]   List recorded architecture-boundary violations (packwerk)
          moult flags [PATH] [options]        Catalogue OpenFeature feature-flag references (usage)
          moult gate [PATH] [options]         Diff-aware PR risk gate: verdict over the changed code
          moult --version                     Print version
          moult --help                        Show this message
      USAGE
    end
  end
end
