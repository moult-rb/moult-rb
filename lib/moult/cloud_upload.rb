# frozen_string_literal: true

module Moult
  # Builds the payload uploaded from CI to Moult Cloud out of a parsed
  # `moult gate --format json` report.
  #
  # The gate report is already SOURCE-FREE by contract (a finding is
  # category/path/symbol_id/line/value -- no code text), so this is not where
  # "no source leaves the repo" is enforced; that is structural. This projection
  # does two narrower jobs:
  #   1. Allow-list the top-level keys -- defence-in-depth so a future formatter
  #      addition cannot silently exfiltrate a new field.
  #   2. Normalise analysis.root to "." -- the raw value is the absolute local
  #      path, which leaks the developer's filesystem layout and is meaningless
  #      to the cloud (it derives the repo from the CI OIDC token).
  # The result stays valid against schema/gate.schema.json (root remains a string).
  module CloudUpload
    TOP_LEVEL_KEYS = %w[
      schema_version tool analysis policy verdict reasons summary rules
    ].freeze

    def self.projection(report)
      allowed = report.slice(*TOP_LEVEL_KEYS)
      analysis = allowed["analysis"]
      allowed["analysis"] = analysis.merge("root" => ".") if analysis.is_a?(Hash)
      allowed
    end
  end
end
