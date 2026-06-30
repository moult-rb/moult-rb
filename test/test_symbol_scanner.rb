# frozen_string_literal: true

require "test_helper"

class TestSymbolScanner < Minitest::Test
  S = Moult::SymbolScanner

  def test_collects_callback_symbols_bare_and_qualified
    src = <<~RUBY
      class UsersController < ApplicationController
        before_action :authenticate, :set_user
        def index; end
      end
    RUBY
    names = S.scan_source(src)
    assert_includes names, "authenticate"
    assert_includes names, "set_user"
    assert_includes names, "UsersController#authenticate"
  end

  def test_collects_validation_and_helper_method_symbols
    src = <<~RUBY
      class Post < ApplicationRecord
        validate :title_present
        before_save :normalize
      end
    RUBY
    names = S.scan_source(src)
    assert_includes names, "title_present"
    assert_includes names, "normalize"
  end

  def test_ignores_non_dsl_calls
    src = <<~RUBY
      class Foo
        some_random_method :not_a_callback
        puts :hello
      end
    RUBY
    names = S.scan_source(src)
    refute_includes names, "not_a_callback"
    refute_includes names, "hello"
  end

  def test_handles_qualified_nesting
    src = <<~RUBY
      module Admin
        class DashboardController
          before_action :require_admin
        end
      end
    RUBY
    names = S.scan_source(src)
    assert_includes names, "require_admin"
    assert_includes names, "Admin::DashboardController#require_admin"
  end
end
