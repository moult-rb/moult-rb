# frozen_string_literal: true

require_relative "lib/moult/version"

Gem::Specification.new do |spec|
  spec.name = "moult-rb"
  spec.version = Moult::VERSION
  spec.authors = ["The Moult authors"]
  spec.email = ["contact@moult.dev"]

  spec.summary = "Confidence-graded codebase intelligence for Ruby and Rails."
  spec.description = "Moult sheds dead code. `moult hotspots` ranks files by a complexity x churn " \
    "score (Prism-parsed ABC complexity per method x per-file git churn); `moult deadcode` lists " \
    "confidence-graded unused-method and unused-constant candidates over a rubydex definition graph, " \
    "with Rails entrypoint awareness. Every finding carries a confidence and its reasons, never a claim of certain death."
  spec.homepage = "https://github.com/moult-rb/moult-rb"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.files = Dir[
    "lib/**/*.rb",
    "schema/**/*.json",
    "exe/*",
    "README.md",
    "LICENSE.txt",
    "NOTICE",
    "CHANGELOG.md"
  ]
  spec.bindir = "exe"
  spec.executables = ["moult"]
  spec.require_paths = ["lib"]

  # Parsing. Prism is the canonical Ruby parser (bundled with Ruby 3.4+).
  spec.add_dependency "prism", ">= 0.24"

  # Definition/reference index + constant resolution (the Zeitwerk-aware
  # semantic layer behind `moult deadcode`). Rust-backed with Ruby bindings,
  # the same engine that powers ruby-lsp. Pinned tight while it is pre-1.0.
  spec.add_dependency "rubydex", "~> 0.2"

  # Structural similarity / clone detection behind `moult duplication`. As of
  # 2.14 flay parses with Prism (the same parser Moult uses) via sexp_processor,
  # so integrating it adds no parallel parser stack. Wrapped by {Moult::Clones},
  # the only file that names it, so it stays swappable.
  spec.add_dependency "flay", "~> 2.14"
end
