# frozen_string_literal: true

module Wallets
  # A transfer records an internal movement of value between two wallets of the
  # same asset. The actual balance impact lives in the linked transactions on
  # each side so the ledger remains append-only.
  #
  # Transfers keep the outbound leg singular and the inbound legs plural so the
  # receiver can preserve the sender's expiration buckets when one transfer
  # consumes multiple source transactions with different expirations.
  class Transfer < ApplicationRecord
    class_attribute :embedded_table_name, default: nil
    class_attribute :config_provider, default: -> { Wallets.configuration }
    class_attribute :transaction_class_name, default: "Wallets::Transaction"

    SUPPORTED_EXPIRATION_POLICIES = %w[preserve none fixed].freeze

    def self.table_name
      embedded_table_name || "#{resolved_config.table_prefix}transfers"
    end

    def self.resolved_config
      value = config_provider
      value.respond_to?(:call) ? value.call : value
    end

    def self.transaction_class
      transaction_class_name.constantize
    end

    belongs_to :from_wallet, class_name: "Wallets::Wallet", inverse_of: :outgoing_transfers
    belongs_to :to_wallet, class_name: "Wallets::Wallet", inverse_of: :incoming_transfers

    has_many :transactions,
             class_name: "Wallets::Transaction",
             foreign_key: :transfer_id,
             inverse_of: :transfer

    validates :asset_code, presence: true
    validates :amount, presence: true, numericality: { only_integer: true, greater_than: 0 }
    validates :expiration_policy, presence: true, inclusion: { in: SUPPORTED_EXPIRATION_POLICIES }
    validate :wallets_must_differ
    validate :wallet_assets_match_transfer_asset

    before_validation :normalize_asset_code!
    before_validation :normalize_expiration_policy!
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

    def outbound_transactions
      transfer_transactions_for(wallet_id: from_wallet_id).where("amount < 0")
    end

    def outbound_transaction
      outbound_transactions.order(:id).first
    end

    def inbound_transactions
      transfer_transactions_for(wallet_id: to_wallet_id).where("amount > 0")
    end

    def inbound_transaction
      records = inbound_transactions.order(:id).limit(2).to_a
      records.one? ? records.first : nil
    end

    private

    def transaction_class
      self.class.transaction_class
    end

    def normalize_asset_code!
      self.asset_code = asset_code.to_s.strip.downcase.presence
    end

    def normalize_expiration_policy!
      self.expiration_policy = expiration_policy.to_s.strip.downcase.presence
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

    def sync_metadata_cache
      if @indifferent_metadata
        write_attribute(:metadata, @indifferent_metadata.to_h)
      elsif read_attribute(:metadata).nil?
        write_attribute(:metadata, {})
      end
    end

    def transfer_transactions_for(wallet_id:)
      return transaction_class.none unless persisted? && wallet_id.present?

      transaction_class.where(transfer_id: id, wallet_id: wallet_id)
    end
  end
end
