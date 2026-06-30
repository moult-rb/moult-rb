# frozen_string_literal: true

# Exercises the OpenFeature client surface for the flag-scanner fixtures: boolean,
# string, number and object fetches; a flag referenced from two methods (multi-site);
# a fetch_<type>_details call; a dynamic (non-literal) key; and a decoy same-named
# call without flag_key: (which must be ignored).
class Billing
  def initialize
    @client = OpenFeature::SDK.build_client
  end

  def checkout
    return unless @client.fetch_boolean_value(flag_key: "new_checkout", default_value: false)

    @discount = @client.fetch_number_value(flag_key: "discount_pct", default_value: 0)
    @label = @client.fetch_string_value(flag_key: "checkout_label", default_value: "Pay")
  end

  def shipping
    # Same flag key referenced from a second method -> one finding, two occurrences.
    return unless @client.fetch_boolean_value(flag_key: "new_checkout", default_value: false)

    @config = @client.fetch_object_value(flag_key: "shipping_config", default_value: {})
    @verbose = @client.fetch_boolean_details(flag_key: "verbose_shipping", default_value: false)
  end

  def dynamic(key)
    # Non-literal flag_key -> a dynamic reference: counted, never catalogued.
    @client.fetch_string_value(flag_key: key, default_value: "x")
  end

  def decoy
    # Same method name, but no flag_key: -> not an OpenFeature evaluation.
    fetch_string_value(default_value: "nope")
  end
end
