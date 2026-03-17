# frozen_string_literal: true

module Wallets
  # A transfer records an internal movement of value between two wallets of the
  # same asset. The actual balance impact lives in the linked transactions on
  # each side so the ledger remains append-only.
  class Transfer < ApplicationRecord
    def self.table_name
      "#{Wallets.configuration.table_prefix}transfers"
    end

    belongs_to :from_wallet, class_name: "Wallets::Wallet", inverse_of: :outgoing_transfers
    belongs_to :to_wallet, class_name: "Wallets::Wallet", inverse_of: :incoming_transfers
    belongs_to :outbound_transaction, class_name: "Wallets::Transaction", optional: true
    belongs_to :inbound_transaction, class_name: "Wallets::Transaction", optional: true

    validates :asset_code, presence: true
    validates :amount, presence: true, numericality: { only_integer: true, greater_than: 0 }
    validate :wallets_must_differ
    validate :wallet_assets_match_transfer_asset
    validate :linked_transactions_match_wallets

    before_validation :normalize_asset_code!
    before_save :sync_metadata_cache

    def metadata
      @indifferent_metadata ||= ActiveSupport::HashWithIndifferentAccess.new(super || {})
    end

    def metadata=(hash)
      @indifferent_metadata = nil
      super(hash.respond_to?(:to_h) ? hash.to_h : {})
    end

    def reload(*)
      @indifferent_metadata = nil
      super
    end

    private

    def normalize_asset_code!
      self.asset_code = asset_code.to_s.strip.downcase.presence
    end

    def wallets_must_differ
      return if from_wallet.blank? || to_wallet.blank?
      return if from_wallet_id != to_wallet_id

      errors.add(:to_wallet, "must be different from from_wallet")
    end

    def wallet_assets_match_transfer_asset
      return if from_wallet.blank? || to_wallet.blank? || asset_code.blank?
      return if from_wallet.asset_code == asset_code && to_wallet.asset_code == asset_code

      errors.add(:asset_code, "must match both wallets")
    end

    def linked_transactions_match_wallets
      if outbound_transaction.present? && from_wallet.present? && outbound_transaction.wallet_id != from_wallet_id
        errors.add(:outbound_transaction, "must belong to the source wallet")
      end

      if inbound_transaction.present? && to_wallet.present? && inbound_transaction.wallet_id != to_wallet_id
        errors.add(:inbound_transaction, "must belong to the target wallet")
      end
    end

    def sync_metadata_cache
      if @indifferent_metadata
        write_attribute(:metadata, @indifferent_metadata.to_h)
      elsif read_attribute(:metadata).nil?
        write_attribute(:metadata, {})
      end
    end
  end
end
