# frozen_string_literal: true

module Web
  class Dashboard
    def render(account)
      # Reaches into another package's private constant (privacy) and into billing
      # without declaring the dependency (dependency).
      token = User::Token.mint(account)
      [token, Billing::Invoice.for(account.id)]
    end
  end
end
