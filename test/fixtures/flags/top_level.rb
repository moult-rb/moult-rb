# frozen_string_literal: true

# A top-level flag reference (outside any method): resolves to a null symbol_id.
client = OpenFeature::SDK.build_client
client.fetch_boolean_value(flag_key: "maintenance_mode", default_value: false)
