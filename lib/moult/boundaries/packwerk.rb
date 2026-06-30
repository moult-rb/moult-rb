# frozen_string_literal: true

require "yaml"
require_relative "../symbol_id"

module Moult
  module Boundaries
    # The architecture-boundary adapter — Moult's reader of Packwerk's on-disk
    # artifacts and the *only* file that names Packwerk. Everything downstream
    # consumes the Moult-owned {Violation}/{Result} value objects, never a packwerk
    # type, so the backend is swappable (the "swap, not rewrite" invariant).
    #
    # Like {Coverage} (which ingests SimpleCov/stdlib coverage *files*), this slice
    # ingests packwerk's *files* rather than booting it: a live `bin/packwerk check`
    # needs a bootable Rails/Zeitwerk app and emits only human prose / new-violation
    # deltas, whereas packwerk *serialises every recorded violation* to stable,
    # diffable `package_todo.yml` files. We read those (the package graph + the
    # recorded violations packwerk already resolved via Zeitwerk) and own no part of
    # the constant-resolution graph. Consequently Moult needs NO packwerk gem
    # dependency (exactly as {Coverage} needs no simplecov). Live re-analysis — the
    # fresh, line-level offense set — is deferred, the same way the Coverband and
    # Flipper live stores are.
    #
    # The `package_todo.yml` shape we parse (packwerk's own serialization):
    #
    #   <defining-package>:            # the package that OWNS the referenced constant
    #     "::Some::Constant":          # the constant crossing the boundary
    #       violations:
    #       - dependency               # one or more violation types
    #       - privacy
    #       files:
    #       - path/to/referencing.rb   # the referencing files (root-relative)
    #
    # The file lives at `<referencing-package-dir>/package_todo.yml`, so the
    # referencing package is the file's directory (root-relative; "." for the root
    # package). packwerk reports violations at FILE granularity (no line numbers),
    # which fixes this slice's join at path level.
    module Packwerk
      module_function

      # A single recorded boundary violation: one referencing file crossing into one
      # constant owned by another package, of one type. Path is root-relative.
      Violation = Struct.new(:violation_type, :referencing_package, :defining_package, :constant, :path)

      # The Moult-owned result of reading a project's packwerk artifacts. +configured+
      # is false when the project has no `packwerk.yml` (not a packwerk project), in
      # which case +violations+ is empty. +backend+/+backend_version+ originate here so
      # "packwerk" stays isolated to this file.
      Result = Struct.new(:violations, :backend, :backend_version, :configured)

      # @param root [String] absolute analysis root
      # @return [Result]
      def detect(root:)
        unless configured?(root)
          return Result.new(violations: [], backend: "packwerk", backend_version: backend_version, configured: false)
        end

        violations = todo_files(root).flat_map { |file| violations_in(file, root) }
        Result.new(violations: violations, backend: "packwerk", backend_version: backend_version, configured: true)
      end

      # A `packwerk.yml` at the root is the unambiguous "this is a packwerk project"
      # marker (it is required for any packwerk run).
      def configured?(root)
        File.exist?(File.join(root, "packwerk.yml"))
      end

      def todo_files(root)
        Dir.glob(File.join(root, "**", "package_todo.yml")).sort
      end

      # Parse one `package_todo.yml` into flat {Violation}s. The referencing package
      # is the file's directory (root-relative). A malformed/empty file is skipped
      # rather than crashing the whole run.
      def violations_in(file, root)
        referencing_package = package_name(File.dirname(file), root)
        data = YAML.safe_load_file(file)
        return [] unless data.is_a?(Hash)

        data.flat_map do |defining_package, constants|
          next [] unless constants.is_a?(Hash)
          constants.flat_map do |constant, detail|
            next [] unless detail.is_a?(Hash)
            types = Array(detail["violations"])
            paths = Array(detail["files"])
            types.product(paths).map do |type, path|
              Violation.new(
                violation_type: type.to_s,
                referencing_package: referencing_package,
                defining_package: defining_package.to_s,
                constant: constant.to_s,
                path: path.to_s
              )
            end
          end
        end
      rescue Psych::Exception
        []
      end

      # Root-relative package name; "." for the root package (packwerk's convention).
      def package_name(dir, root)
        SymbolId.relative_path(dir, root)
      end

      # packwerk is not a Moult dependency, so its constant is normally absent; the
      # version is recorded when it happens to be loaded, else nil (nullable in the
      # contract). This is the only reference to the Packwerk constant in Moult.
      def backend_version
        defined?(::Packwerk::VERSION) ? ::Packwerk::VERSION : nil
      end
    end
  end
end
