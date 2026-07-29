# frozen_string_literal: true

module Wallets
  # Wallet-specific adapter for the shared callback dispatcher.
  module Callbacks
    extend Wallets::CallbackDispatcher

    module_function

    def callback_configuration
      Wallets.configuration
    end

    def callback_context_class
      Wallets::CallbackContext
    end

    def callback_log_prefix
      "[Wallets]"
    end
  end
end
