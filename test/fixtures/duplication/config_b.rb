# frozen_string_literal: true

SETTINGS_B = {
  timeout: 30,
  retries: 3,
  backoff: 1.5,
  endpoints: ["alpha", "beta", "gamma"],
  headers: {accept: "json", agent: "moult"}
}.freeze
