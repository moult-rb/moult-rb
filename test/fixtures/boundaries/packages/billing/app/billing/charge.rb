# frozen_string_literal: true

module Billing
  class Charge
    def self.run(account_id)
      # Another undeclared reference into the user package.
      User::Account.new(account_id)
    end
  end
end
