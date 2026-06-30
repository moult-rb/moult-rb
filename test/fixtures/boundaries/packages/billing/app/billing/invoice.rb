# frozen_string_literal: true

module Billing
  class Invoice
    # Crosses into the user package without declaring a dependency on it.
    def self.for(account_id)
      new(User::Account.new(account_id))
    end

    def initialize(account)
      @account = account
    end
  end
end
