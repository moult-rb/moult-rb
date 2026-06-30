# frozen_string_literal: true

# A top-level constant whose value structure is duplicated in config_b.rb. The
# clone sits outside any method, so its occurrences resolve to a null symbol_id —
# exercising the best-effort attribution's honest "not inside a known method" path.
SETTINGS_A = {
  timeout: 30,
  retries: 3,
  backoff: 1.5,
  endpoints: ["alpha", "beta", "gamma"],
  headers: {accept: "json", agent: "moult"}
}.freeze
