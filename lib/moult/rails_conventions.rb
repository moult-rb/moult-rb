# frozen_string_literal: true

require_relative "symbol_scanner"

module Moult
  # Models the Rails entrypoint conventions that make framework-invoked code
  # *look* unused. In Rails most "uncalled" methods are reached by convention
  # (controller actions via routing, jobs via `#perform`) or by symbol-based
  # DSLs (`before_action :authenticate`) that no static call site references.
  #
  # This layer never hides a finding (per Moult's core principle,
  # metaprogramming/conventions must *lower* confidence, never silently hide). It only emits {Signal}s that
  # the +:rails_entrypoint+ confidence rule turns into a strong, *explained*
  # downward adjustment. A genuinely dead controller action therefore still
  # appears — just sorted low — rather than being asserted alive.
  #
  # Scope (Tier A): controller/mailer actions, helpers, job `#perform`, symbol-
  # DSL callbacks, serializers, initializers. Classes/modules are not flagged at
  # all (only methods and non-class constants are candidates), which sidesteps
  # STI/Zeitwerk false positives for this slice. Route-file and view-template
  # resolution are deferred.
  class RailsConventions
    Signal = Struct.new(:rule, :detail)

    CONTROLLER = %r{(\A|/)app/controllers/.+_controller\.rb\z}
    MAILER = %r{(\A|/)app/mailers/.+\.rb\z}
    HELPER = %r{(\A|/)app/helpers/.+\.rb\z}
    JOB = %r{(\A|/)app/jobs/.+\.rb\z}
    SERIALIZER = %r{(\A|/)app/serializers/.+\.rb\z}
    INITIALIZER = %r{(\A|/)config/initializers/.+\.rb\z}

    PERFORM_METHODS = %w[perform perform_async perform_later perform_now].freeze

    class << self
      # @param root [String] absolute analysis root
      # @param files [Array<String>] absolute Ruby file paths (for DSL scan)
      # @return [RailsConventions]
      def build(root:, files:)
        rails = rails_app?(root)
        refs = rails ? collect_dsl_references(files) : Set.new
        new(rails: rails, dsl_references: refs)
      end

      def rails_app?(root)
        return true if File.file?(File.join(root, "config", "application.rb"))
        File.directory?(File.join(root, "app")) && gemfile_mentions_rails?(root)
      end

      def gemfile_mentions_rails?(root)
        gemfile = File.join(root, "Gemfile")
        return false unless File.file?(gemfile)
        File.foreach(gemfile).any? { |line| line =~ /^\s*gem\s+["'](rails|railties)["']/ }
      rescue
        false
      end

      def collect_dsl_references(files)
        files.each_with_object(Set.new) do |path, set|
          SymbolScanner.scan_file(path).each { |name| set << name }
        rescue
          next
        end
      end
    end

    # @param rails [Boolean] whether the project is a Rails app
    # @param dsl_references [Set<String>] method names referenced via DSL symbols
    def initialize(rails:, dsl_references: Set.new)
      @rails = rails
      @dsl_references = dsl_references
    end

    def rails?
      @rails
    end

    # @param definition [Index::Definition]
    # @return [Array<Signal>] matched entrypoint conventions (empty if none / not Rails)
    def signals_for(definition)
      return [] unless @rails

      [path_signal(definition), symbol_signal(definition)].compact
    end

    private

    def path_signal(definition)
      return nil unless definition.kind == :method
      path = definition.path.to_s

      case path
      when CONTROLLER
        action_signal(definition, :rails_controller_action, "public action in #{path}")
      when MAILER
        action_signal(definition, :rails_mailer_action, "public mailer action in #{path}")
      when HELPER
        Signal.new(rule: :rails_helper, detail: "helper method in #{path}")
      when JOB
        if PERFORM_METHODS.include?(definition.unqualified_name)
          Signal.new(rule: :rails_job_perform, detail: "job entrypoint #{definition.unqualified_name} in #{path}")
        end
      when SERIALIZER
        Signal.new(rule: :rails_serializer, detail: "serializer method in #{path}")
      when INITIALIZER
        Signal.new(rule: :rails_initializer, detail: "runs at boot in #{path}")
      end
    end

    # Public instance methods of controllers/mailers are framework-invoked
    # actions; private/protected ones are helpers reached only via call or
    # symbol-DSL, so they are left to the normal rules.
    def action_signal(definition, rule, detail)
      return nil unless definition.visibility == :public
      Signal.new(rule: rule, detail: detail)
    end

    def symbol_signal(definition)
      return nil unless definition.kind == :method
      return nil unless @dsl_references.include?(definition.unqualified_name)

      Signal.new(rule: :rails_callback, detail: "referenced as a DSL symbol (e.g. before_action :#{definition.unqualified_name})")
    end
  end
end
