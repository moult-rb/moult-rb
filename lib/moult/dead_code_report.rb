# frozen_string_literal: true

module Moult
  # The serialized result model for `moult deadcode`, sibling to {Report}. It
  # owns the JSON envelope (schema/deadcode.schema.json) and leaves the protected
  # hotspots {Report} untouched. The findings it carries are
  # {Confidence::Finding} objects — the per-finding confidence model is the
  # protected API, so this class only adds the report-level envelope around it.
  class DeadCodeReport
    # Bump only on a breaking change to the serialized shape. v2 adds the
    # Phase 3 runtime block: analysis.coverage provenance and a per-finding
    # runtime classification (both null when no coverage was merged).
    SCHEMA_VERSION = 2

    attr_reader :root, :findings, :git_ref, :generated_at,
      :backend, :backend_version, :resolved, :rails, :diagnostics, :coverage_source

    # @param root [String] absolute analysis root
    # @param findings [Array<Confidence::Finding>] ranked, most-likely-dead first
    # @param git_ref [String, nil] HEAD sha when run inside a repo
    # @param generated_at [String, nil] ISO8601 timestamp
    # @param backend [String] index backend name (e.g. "rubydex")
    # @param backend_version [String, nil] backend gem version
    # @param resolved [Boolean] whether the index fully resolved
    # @param rails [Boolean] whether Rails entrypoint awareness was applied
    # @param diagnostics [Array<String>] non-fatal index diagnostics
    # @param coverage_source [Coverage::Source, nil] provenance of merged runtime
    #   coverage; nil when `moult deadcode` was run without --coverage
    def initialize(root:, findings:, git_ref: nil, generated_at: nil,
      backend: "rubydex", backend_version: nil, resolved: true, rails: false, diagnostics: [],
      coverage_source: nil)
      @root = root
      @findings = findings
      @git_ref = git_ref
      @generated_at = generated_at
      @backend = backend
      @backend_version = backend_version
      @resolved = resolved
      @rails = rails
      @diagnostics = diagnostics
      @coverage_source = coverage_source
    end

    def to_h
      {
        schema_version: SCHEMA_VERSION,
        tool: {name: "moult", version: Moult::VERSION},
        analysis: {
          root: root,
          git_ref: git_ref,
          generated_at: generated_at,
          coverage: coverage_source&.to_h,
          index: {
            backend: backend,
            backend_version: backend_version,
            resolved: resolved,
            rails: rails,
            diagnostics: diagnostics
          }
        },
        findings: findings.map(&:to_h)
      }
    end
  end
end
