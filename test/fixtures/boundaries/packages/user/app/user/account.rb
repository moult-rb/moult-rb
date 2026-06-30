# frozen_string_literal: true

module User
  class Account
    def initialize(id)
      @id = id
    end

    attr_reader :id
  end

  # Intentionally NOT in app/public/ — a private constant of the user package.
  class Token
    def self.mint(account)
      "tok-#{account.id}"
    end
  end
end
