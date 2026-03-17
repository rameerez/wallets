# frozen_string_literal: true

module Wallets
  class Engine < ::Rails::Engine
    isolate_namespace Wallets

    # Load wallet models early so host apps can reference them during boot.
    config.autoload_paths << File.expand_path("models", __dir__)
    config.autoload_paths << File.expand_path("models/concerns", __dir__)

    initializer "wallets.autoload", before: :set_autoload_paths do |app|
      app.config.autoload_paths << root.join("lib")
      app.config.autoload_paths << root.join("lib/wallets/models")
      app.config.autoload_paths << root.join("lib/wallets/models/concerns")
    end

    initializer "wallets.active_record" do
      ActiveSupport.on_load(:active_record) do
        extend Wallets::HasWallets::ClassMethods
      end
    end
  end
end
