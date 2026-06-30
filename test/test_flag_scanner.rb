# frozen_string_literal: true

require "test_helper"

# Pins the OpenFeature call-shape detection. The scanner is the one file that knows
# the OpenFeature client surface; these tests fix what it recognises (and, just as
# important, what it ignores) so a future SDK shift is a deliberate, tested change.
class TestFlagScanner < Minitest::Test
  S = Moult::FlagScanner

  def scan(source)
    S.scan_source(source, "app.rb")
  end

  def by_key(sites, key)
    sites.find { |s| s.flag_key == key }
  end

  def test_detects_each_value_type_from_the_fetch_method
    sites = scan(<<~RUBY)
      client.fetch_boolean_value(flag_key: "a", default_value: false)
      client.fetch_string_value(flag_key: "b", default_value: "x")
      client.fetch_number_value(flag_key: "c", default_value: 0)
      client.fetch_object_value(flag_key: "d", default_value: {})
    RUBY
    assert_equal "boolean", by_key(sites, "a").value_type
    assert_equal "string", by_key(sites, "b").value_type
    assert_equal "number", by_key(sites, "c").value_type
    assert_equal "object", by_key(sites, "d").value_type
  end

  def test_integer_and_float_fetches_collapse_to_number
    sites = scan(<<~RUBY)
      client.fetch_integer_value(flag_key: "i", default_value: 1)
      client.fetch_float_value(flag_key: "f", default_value: 1.5)
    RUBY
    assert_equal "number", by_key(sites, "i").value_type
    assert_equal "number", by_key(sites, "f").value_type
  end

  def test_detects_the_details_variant
    site = scan('client.fetch_boolean_details(flag_key: "x", default_value: false)').first
    assert_equal "fetch_boolean_details", site.method_name
    assert_equal "boolean", site.value_type
  end

  def test_records_method_name_and_line
    site = scan("\nclient.fetch_string_value(flag_key: \"x\", default_value: \"y\")").first
    assert_equal "fetch_string_value", site.method_name
    assert_equal 2, site.line
  end

  def test_extracts_literal_default_values
    sites = scan(<<~RUBY)
      client.fetch_boolean_value(flag_key: "b", default_value: false)
      client.fetch_string_value(flag_key: "s", default_value: "hi")
      client.fetch_number_value(flag_key: "n", default_value: 42)
    RUBY
    assert_equal "false", by_key(sites, "b").default_value
    assert_equal "hi", by_key(sites, "s").default_value
    assert_equal "42", by_key(sites, "n").default_value
  end

  def test_non_literal_default_is_nil_not_guessed
    site = scan('client.fetch_object_value(flag_key: "o", default_value: {})').first
    assert_nil site.default_value
  end

  def test_accepts_a_symbol_flag_key
    site = scan("client.fetch_boolean_value(flag_key: :enabled, default_value: false)").first
    assert_equal "enabled", site.flag_key
  end

  def test_non_literal_flag_key_is_a_dynamic_site_with_nil_key
    site = scan('client.fetch_string_value(flag_key: key, default_value: "x")').first
    assert_nil site.flag_key
    assert_equal "string", site.value_type
  end

  def test_ignores_a_same_named_call_without_a_flag_key_keyword
    assert_empty scan('fetch_string_value(default_value: "nope")')
  end

  def test_ignores_unrelated_calls
    assert_empty scan('client.fetch_user(flag_key: "x")')
    assert_empty scan("OpenFeature::SDK.build_client")
  end
end
