# frozen_string_literal: true

require "test_helper"

# Drives the gate end to end over a REAL temp git repo with a base commit and a
# working-tree diff, so the merge-base resolution + changed-line-range recovery
# (the genuinely new path) stays honest — mirroring how the health/coverage tests
# build temp projects. Pure parsing/policy are pinned separately in test_diff.rb /
# test_gate_policy.rb; this exercises the wiring that joins them.
class TestGate < Minitest::Test
  def setup
    skip "rubydex unavailable" unless Moult::Index.available?
  end

  CLEAN = <<~RUBY
    class App
      def run
        compute
      end

      def compute
        1 + 1
      end
    end
  RUBY

  # Same file plus a freshly-added, unreferenced private method -> a high-confidence
  # new dead-code candidate on changed lines.
  WITH_NEW_DEAD = <<~RUBY
    class App
      def run
        compute
      end

      def compute
        1 + 1
      end

      private

      def orphan
        99
      end
    end
  RUBY

  def test_new_dead_code_on_changed_lines_fails_the_gate
    committed_git_repo("app.rb" => CLEAN) do |root, base|
      write_source(root, "app.rb", WITH_NEW_DEAD)
      report = gate(root, base_ref: base, scope: :diff)

      assert_equal "fail", report.verdict
      dead = rule(report, "no_new_dead_code")
      assert_equal false, dead.passed
      finding = dead.findings.find { |f| f.path == "app.rb" }
      refute_nil finding, "the orphan private method should contribute"
      assert_operator finding.value, :>=, 0.8
    end
  end

  def test_merge_base_is_resolved_and_recorded
    committed_git_repo("app.rb" => CLEAN) do |root, base|
      write_source(root, "app.rb", WITH_NEW_DEAD)
      report = gate(root, base_ref: base, scope: :diff)
      assert_equal base, report.base_ref
      assert_equal base, report.merge_base, "base is a direct ancestor, so it is its own merge-base"
      assert_equal :diff, report.scope
    end
  end

  def test_finding_outside_the_diff_does_not_fail
    # The dead method exists in the BASE already; the only change is an unrelated
    # comment far from it, so nothing dead is on the changed lines.
    committed_git_repo("app.rb" => WITH_NEW_DEAD) do |root, base|
      write_source(root, "app.rb", "# unrelated top comment\n#{WITH_NEW_DEAD}")
      report = gate(root, base_ref: base, scope: :diff)

      # The orphan shifted down by one line but its body lines are unchanged; the
      # only changed line is the new comment at the top.
      assert_equal "pass", report.verdict, "pre-existing dead code is not NEW code"
      assert_equal true, rule(report, "no_new_dead_code").passed
    end
  end

  def test_scope_all_gates_the_whole_codebase
    committed_git_repo("app.rb" => WITH_NEW_DEAD) do |root, base|
      # No working-tree change at all; diff scope would be empty and pass.
      diff_report = gate(root, base_ref: base, scope: :diff)
      assert_equal "pass", diff_report.verdict

      all_report = gate(root, base_ref: base, scope: :all)
      assert_equal "fail", all_report.verdict, "the pre-existing dead method is caught under --scope all"
      assert_nil all_report.merge_base
    end
  end

  def test_non_packwerk_repo_skips_the_boundary_rule
    committed_git_repo("app.rb" => WITH_NEW_DEAD) do |root, base|
      report = gate(root, base_ref: base, scope: :all)
      boundary = rule(report, "no_new_high_severity_boundary")
      refute boundary.evaluated
      component = report.components.find { |c| c.name == "boundaries" }
      refute component.present
      assert_match(/packwerk/, component.diagnostic)
    end
  end

  def test_unresolvable_base_raises_a_clear_error
    committed_git_repo("app.rb" => CLEAN) do |root, _base|
      error = assert_raises(Moult::Error) { gate(root, base_ref: "does/not/exist", scope: :diff) }
      assert_match(/merge-base/, error.message)
    end
  end

  private

  def gate(root, base_ref:, scope:)
    files = Moult::Discovery.ruby_files(root)
    index = Moult::Index.build(root: root, paths: files)
    rails = Moult::RailsConventions.new(rails: false)
    Moult::Gate.build_report(
      root: root, files: files, index: index, rails: rails,
      base_ref: base_ref, scope: scope, policy: Moult::Gate::Policy.default
    )
  end

  def rule(report, name)
    report.rules.find { |r| r.rule == name }
  end
end

# Scoping is pure given a Diff, so the per-occurrence duplication fan-out is
# pinned directly (no need to coax flay into an over-threshold clone).
class TestGateScoping < Minitest::Test
  def test_duplication_scopes_one_observation_per_in_diff_occurrence
    run = Moult::Gate::Run.new(value: sample_duplication_report, error: nil)
    diff = Moult::Diff.compute(root: nil, base_ref: nil, scope: :all)

    obs = Moult::Gate.scope_duplication(run, diff)

    assert_equal 4, obs.size, "every occurrence of every group becomes an observation"
    identical = obs.select { |o| o.clone_group == "identical:190423" }
    assert_equal ["app/models/account.rb", "app/models/user.rb"], identical.map(&:path).sort
    assert(identical.all? { |o| o.mass == 92 }, "mass stays a group property on every occurrence")
  end
end
