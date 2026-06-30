# frozen_string_literal: true

require_relative "moult/version"

# Moult provides confidence-graded codebase intelligence for Ruby.
#
# Phase 1 exposes a single capability: ranking files by a complexity x churn
# hotspot score. See {Moult::CLI} for the command-line entrypoint.
module Moult
  class Error < StandardError; end

  autoload :CLI, "moult/cli"
  autoload :Parser, "moult/parser"
  autoload :MethodDef, "moult/parser"
  autoload :ABC, "moult/abc"
  autoload :Churn, "moult/churn"
  autoload :Git, "moult/git"
  autoload :Scoring, "moult/scoring"
  autoload :Discovery, "moult/discovery"
  autoload :Report, "moult/report"
  autoload :Span, "moult/span"
  autoload :SymbolId, "moult/symbol_id"

  # Phase 2: confidence-graded dead-code analysis.
  autoload :Index, "moult/index"
  autoload :Confidence, "moult/confidence"
  autoload :DeadCode, "moult/dead_code"
  autoload :DeadCodeReport, "moult/dead_code_report"
  autoload :RailsConventions, "moult/rails_conventions"
  autoload :SymbolScanner, "moult/symbol_scanner"

  # Phase 3: runtime coverage layer (static<->runtime merge).
  autoload :Coverage, "moult/coverage"
  autoload :CoverageReport, "moult/coverage_report"

  # Static slice: flay-backed structural duplication detection.
  autoload :Clones, "moult/clones"
  autoload :Duplication, "moult/duplication"
  autoload :DuplicationReport, "moult/duplication_report"

  # Health slice: a composite health score aggregating the other analyses.
  autoload :Health, "moult/health"
  autoload :HealthReport, "moult/health_report"

  # Static slice: packwerk-backed architecture-boundary violations.
  autoload :Boundaries, "moult/boundaries"
  autoload :BoundariesReport, "moult/boundaries_report"

  # Static slice: OpenFeature feature-flag usage (provider-agnostic).
  autoload :FlagScanner, "moult/flag_scanner"
  autoload :Flags, "moult/flags"
  autoload :FlagsReport, "moult/flags_report"

  # Phase 4 (core): the diff-aware PR risk gate — the first/only verdict layer.
  autoload :Diff, "moult/diff"
  autoload :Gate, "moult/gate"
  autoload :GateReport, "moult/gate_report"

  # Cloud upload: sanitising projection for the moult-action GitHub Action.
  autoload :CloudUpload, "moult/cloud_upload"

  module Formatters
    autoload :TextTable, "moult/formatters/text_table"
    autoload :Table, "moult/formatters/table"
    autoload :Json, "moult/formatters/json"
    autoload :DeadCodeTable, "moult/formatters/dead_code_table"
    autoload :DeadCodeJson, "moult/formatters/dead_code_json"
    autoload :CoverageTable, "moult/formatters/coverage_table"
    autoload :CoverageJson, "moult/formatters/coverage_json"
    autoload :DuplicationTable, "moult/formatters/duplication_table"
    autoload :DuplicationJson, "moult/formatters/duplication_json"
    autoload :HealthTable, "moult/formatters/health_table"
    autoload :HealthJson, "moult/formatters/health_json"
    autoload :BoundariesTable, "moult/formatters/boundaries_table"
    autoload :BoundariesJson, "moult/formatters/boundaries_json"
    autoload :FlagsTable, "moult/formatters/flags_table"
    autoload :FlagsJson, "moult/formatters/flags_json"
    autoload :GateMessage, "moult/formatters/gate_message"
    autoload :GateTable, "moult/formatters/gate_table"
    autoload :GateJson, "moult/formatters/gate_json"
    autoload :GateGithub, "moult/formatters/gate_github"
    autoload :GateSarif, "moult/formatters/gate_sarif"
  end
end
