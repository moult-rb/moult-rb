# frozen_string_literal: true

require "test_helper"

class TestVersion < Minitest::Test
  def test_version_is_defined
    refute_nil Moult::VERSION
    assert_match(/\A\d+\.\d+\.\d+/, Moult::VERSION)
  end
end
