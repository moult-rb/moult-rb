# frozen_string_literal: true

require "test_helper"
require "json"

# Pins {Flags::Snapshot} — the sole keeper of the provider export format, the flags
# analogue of {Coverage}'s ingestion. These tests fix what it recognises in a flagd
# flag-definition export and how it normalises each flagd quirk into Moult's own
# {FlagState}, so a future provider/standard shift is a deliberate, tested change.
class TestFlagsSnapshot < Minitest::Test
  S = Moult::Flags::Snapshot

  def load_fixture
    S.load(fixture_path("flags", "provider", "flagd.json"))
  end

  # ---- normalisation ---------------------------------------------------------

  def test_loads_every_flag_key_known_to_the_provider
    set = load_fixture
    assert set.key?("new_checkout")
    assert set.key?("legacy_only")
    refute set.key?("maintenance_mode"), "a key absent from the export must not appear"
  end

  def test_enabled_maps_from_state
    set = load_fixture
    assert_equal true, set.state_for("new_checkout").enabled
    assert_equal false, set.state_for("checkout_label").enabled
  end

  def test_targeting_presence_is_normalised
    set = load_fixture
    assert_equal true, set.state_for("new_checkout").has_targeting, "a non-empty targeting object"
    assert_equal false, set.state_for("discount_pct").has_targeting, "no targeting -> fully rolled out"
  end

  def test_archived_reads_from_metadata_boolean
    assert_equal true, load_fixture.state_for("shipping_config").archived
  end

  def test_archived_reads_from_metadata_lifecycle
    assert_equal true, load_fixture.state_for("verbose_shipping").archived,
      "lifecycle: deprecated normalises to archived"
  end

  def test_unarchived_flag_is_not_archived
    assert_equal false, load_fixture.state_for("new_checkout").archived
  end

  def test_default_variant_and_updated_at_are_captured
    set = load_fixture
    assert_equal "off", set.state_for("new_checkout").default_variant
    assert_equal "2025-01-15T00:00:00Z", set.state_for("shipping_config").updated_at
    assert_nil set.state_for("new_checkout").updated_at
  end

  def test_source_provenance
    source = load_fixture.source
    assert_equal "flagd", source.backend
    assert_equal "42", source.version
    assert_equal "2026-06-01T00:00:00Z", source.exported_at
  end

  def test_forcing_the_flagd_format_matches_auto_detection
    forced = S.load(fixture_path("flags", "provider", "flagd.json"), format: :flagd)
    assert_equal load_fixture.states.keys.sort, forced.states.keys.sort
  end

  # ---- error paths (raise Moult::Error, like Coverage.load) ------------------

  def test_missing_file_raises_moult_error
    err = assert_raises(Moult::Error) { S.load(fixture_path("flags", "provider", "nope.json")) }
    assert_match(/no such provider snapshot/, err.message)
  end

  def test_malformed_json_raises_moult_error
    err = assert_raises(Moult::Error) { S.load(fixture_path("flags", "provider", "malformed.json")) }
    assert_match(/could not parse/, err.message)
  end

  def test_unrecognised_shape_raises_moult_error
    err = assert_raises(Moult::Error) { S.load(fixture_path("flags", "provider", "not_flagd.json")) }
    assert_match(/could not auto-detect/, err.message)
  end

  def test_unknown_forced_format_raises_moult_error
    err = assert_raises(Moult::Error) do
      S.load(fixture_path("flags", "provider", "flagd.json"), format: :launchdarkly)
    end
    assert_match(/unknown provider snapshot format/, err.message)
  end
end
