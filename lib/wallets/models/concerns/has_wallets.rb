# frozen_string_literal: true

module Wallets
  # Adds multi-wallet ownership to an Active Record model.
  # One owner can have one wallet per asset code, with a default "main wallet"
  # exposed via `owner.wallet` and `owner.main_wallet`.
  module HasWallets
    extend ActiveSupport::Concern

    class_methods do
      def has_wallets(**options)
        include Wallets::HasWallets unless included_modules.include?(Wallets::HasWallets)

        @wallet_options = options
      end

      # Resolved lazily on every call so subclasses inherit their parent's
      # `has_wallets` declaration and so `Wallets.configuration.default_asset`
      # is honored no matter when the host app's initializer ran.
      def wallet_options
        {
          default_asset: Wallets.configuration.default_asset,
          auto_create: true,
          initial_balance: 0
        }.merge(declared_wallet_options)
      end

      private

      def declared_wallet_options
        if defined?(@wallet_options) && @wallet_options
          @wallet_options
        elsif superclass.respond_to?(:declared_wallet_options, true)
          superclass.send(:declared_wallet_options)
        else
          {}
        end
      end
    end

    included do
      has_many :wallets,
               class_name: "Wallets::Wallet",
               as: :owner,
               dependent: :destroy

      after_create :create_main_wallet, if: :should_auto_create_wallet?
    end

    def wallet_options
      self.class.wallet_options
    end

    def wallet(asset_code = nil)
      ensure_wallet(asset_code || wallet_options[:default_asset])
    end

    def wallet?(asset_code = nil)
      find_wallet(asset_code).present?
    end

    def main_wallet
      wallet(wallet_options[:default_asset])
    end

    def find_wallet(asset_code = nil)
      normalized_asset_code = Wallets.normalize_asset_code(asset_code || wallet_options[:default_asset])
      wallets.find_by(asset_code: normalized_asset_code)
    end

    private

    def should_auto_create_wallet?
      wallet_options[:auto_create] != false
    end

    def ensure_wallet(asset_code)
      existing_wallet = find_wallet(asset_code)
      return existing_wallet if existing_wallet.present?
      return unless should_auto_create_wallet?
      raise Wallets::Error, "Cannot create wallet for unsaved owner" unless persisted?

      Wallet.create_for_owner!(
        owner: self,
        asset_code: asset_code,
        initial_balance: initial_balance_for(asset_code)
      )
    end

    def create_main_wallet
      main_wallet
    end

    def initial_balance_for(asset_code)
      return 0 unless Wallets.normalize_asset_code(asset_code) == Wallets.normalize_asset_code(wallet_options[:default_asset])

      wallet_options[:initial_balance] || 0
    end
  end
end
