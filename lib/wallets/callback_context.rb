# frozen_string_literal: true

module Wallets
  # Immutable event payload passed to lifecycle callbacks.
  # Keeping callback data in one object makes it easier to extend callback APIs
  # without breaking existing handlers.
  CallbackContext = Struct.new(
    :event,
    :wallet,
    :transfer,
    :amount,
    :previous_balance,
    :new_balance,
    :threshold,
    :category,
    :transaction,
    :metadata,
    keyword_init: true
  ) do
    def owner
      wallet&.owner
    end

    def to_h
      super.compact
    end
  end
end
