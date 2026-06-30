# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestRailsConventions < Minitest::Test
  RC = Moult::RailsConventions

  def defn(path:, name: "Foo#bar", unqualified: "bar", kind: :method, visibility: :public)
    Moult::Index::Definition.new(
      symbol_id: "#{path}:1:#{name}", kind: kind, name: name,
      unqualified_name: unqualified, owner: "Foo", visibility: visibility,
      singleton: false, span: nil, path: path, reference_count: 0, reference_paths: []
    )
  end

  def rails(dsl: [])
    RC.new(rails: true, dsl_references: Set.new(dsl))
  end

  # ---- detection gate -------------------------------------------------------

  def test_detects_rails_via_config_application
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "config"))
      File.write(File.join(root, "config", "application.rb"), "class App < Rails::Application; end")
      assert RC.rails_app?(root)
    end
  end

  def test_plain_ruby_project_is_not_rails_and_signals_are_noop
    Dir.mktmpdir do |root|
      refute RC.rails_app?(root)
      rc = RC.build(root: root, files: [])
      refute rc.rails?
      assert_empty rc.signals_for(defn(path: "app/controllers/users_controller.rb"))
    end
  end

  # ---- path conventions -----------------------------------------------------

  def test_public_controller_action_flagged
    sigs = rails.signals_for(defn(path: "app/controllers/users_controller.rb", visibility: :public))
    assert_equal [:rails_controller_action], sigs.map(&:rule)
  end

  def test_private_controller_method_not_an_action
    sigs = rails.signals_for(defn(path: "app/controllers/users_controller.rb", visibility: :private))
    refute_includes sigs.map(&:rule), :rails_controller_action
  end

  def test_helper_method_flagged
    sigs = rails.signals_for(defn(path: "app/helpers/users_helper.rb"))
    assert_equal [:rails_helper], sigs.map(&:rule)
  end

  def test_job_perform_flagged_but_other_methods_not
    assert_equal [:rails_job_perform],
      rails.signals_for(defn(path: "app/jobs/email_job.rb", unqualified: "perform")).map(&:rule)
    assert_empty rails.signals_for(defn(path: "app/jobs/email_job.rb", unqualified: "internal_helper"))
  end

  def test_initializer_and_serializer
    assert_equal [:rails_initializer],
      rails.signals_for(defn(path: "config/initializers/setup.rb")).map(&:rule)
    assert_equal [:rails_serializer],
      rails.signals_for(defn(path: "app/serializers/user_serializer.rb")).map(&:rule)
  end

  # ---- symbol-DSL references ------------------------------------------------

  def test_callback_symbol_reference_flags_method
    rc = rails(dsl: ["authenticate"])
    sigs = rc.signals_for(defn(path: "app/controllers/users_controller.rb", unqualified: "authenticate", visibility: :private))
    assert_includes sigs.map(&:rule), :rails_callback
  end

  def test_no_signal_for_unmatched_method
    rc = rails(dsl: ["something_else"])
    assert_empty rc.signals_for(defn(path: "app/models/user.rb", unqualified: "untouched", visibility: :private))
  end
end
