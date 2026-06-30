# frozen_string_literal: true

require "open3"

module Moult
  # Thin, injection-safe wrapper over the git CLI. All commands run with an
  # explicit working directory and argument array (never a shell string), and
  # failures surface as nil/false rather than exceptions so callers can degrade
  # gracefully outside a repository.
  module Git
    module_function

    # @return [Boolean] whether +dir+ is inside a git work tree
    def repo?(dir)
      out, _, status = Open3.capture3("git", "rev-parse", "--is-inside-work-tree", chdir: dir)
      status.success? && out.strip == "true"
    rescue SystemCallError
      false
    end

    # @return [String, nil] the HEAD commit sha, or nil outside a repo
    def head_ref(dir)
      out = capture(dir, "rev-parse", "HEAD")
      out&.strip
    end

    # @return [Array<String>] tracked + untracked-but-not-ignored files,
    #   relative to +dir+, respecting .gitignore. Empty outside a repo.
    def listed_files(dir)
      out = capture(dir, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
      return [] unless out

      out.split("\x0").reject(&:empty?)
    end

    # Raw `git log` file listing for churn: one path per line, blank lines
    # between commits. Each commit lists a touched path at most once.
    # @return [String, nil] nil outside a repo
    def log_name_only(dir, since:)
      capture(dir, "log", "--since=#{since}", "--name-only", "--pretty=format:")
    end

    # ---- diff adapter (drives the PR risk gate's diff scoping) ----------------
    #
    # These three are the ONLY git calls behind the diff-aware gate. They return
    # raw text (or nil/false on failure); {Diff} owns all parsing, so this file
    # stays the single shell gateway and the parser can be pinned in isolation.

    # The common ancestor of +base_ref+ and HEAD — the "new code" boundary, the
    # same merge-base semantics SonarQube/CodeScene use to scope a diff.
    # @return [String, nil] the merge-base sha, or nil if it can't be resolved
    #   (base_ref unknown, shallow clone with no common history, outside a repo)
    def merge_base(dir, base_ref)
      out = capture(dir, "merge-base", base_ref, "HEAD")
      out&.strip
    end

    # `git diff --name-status REF`: one "<status>\t<path>" line per changed file
    # between +ref+ and the working tree (renames carry two paths). Empty string
    # when nothing changed; nil on failure.
    # @return [String, nil]
    def diff_name_status(dir, ref)
      capture(dir, "diff", "--name-status", ref)
    end

    # `git diff --unified=0 REF`: a context-free unified diff between +ref+ and the
    # working tree. Zero context means each hunk header's new-side range
    # (`@@ -a,b +c,d @@`) is exactly the changed/added lines — what the gate needs
    # to scope findings to the diff. Empty string when nothing changed; nil on failure.
    # @return [String, nil]
    def diff_unified_zero(dir, ref)
      capture(dir, "diff", "--unified=0", ref)
    end

    # Run a git subcommand, returning stdout, or nil on any failure.
    def capture(dir, *args)
      out, _, status = Open3.capture3("git", *args, chdir: dir)
      status.success? ? out : nil
    rescue SystemCallError
      nil
    end
  end
end
