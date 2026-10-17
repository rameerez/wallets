# frozen_string_literal: true

module Wallets
  class Engine < ::Rails::Engine
    isolate_namespace Wallets

    # All gem code is required eagerly by lib/wallets.rb, so nothing here is
    # added to the host app's autoload paths. Registering lib/wallets/models
    # with Zeitwerk would claim top-level constants like ::Wallet and
    # ::Transaction and shadow (break) host apps that define models with
    # those very common names.

    initializer "wallets.active_record" do
      ActiveSupport.on_load(:active_record) do
        extend Wallets::HasWallets::ClassMethods
      end
    end
  end
end
