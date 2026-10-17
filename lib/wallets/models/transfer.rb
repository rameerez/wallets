# frozen_string_literal: true

module Wallets
  # A transfer records an internal movement of value between two wallets of the
  # same asset. The actual balance impact lives in the linked transactions on
  # each side so the transaction history remains explicit.
  #
  # Transfers keep the outbound leg singular and the inbound legs plural so the
  # receiver can preserve the sender's expiration buckets when one transfer
  # consumes multiple source transactions with different expirations.
  class TransferBase < ApplicationRecord
    # Abstract on purpose: embedders (like usage_credits) subclass THIS
    # class, not the concrete Transfer below. ActiveRecord builds a
    # subclass's attribute methods on its parent's, so a concrete parent
    # forces a schema load of the wallets_* tables — which do not exist in
    # apps that only run an embedded ledger (fresh usage_credits installs).
    # An abstract parent makes each embedded subclass its own base_class
    # and keeps the base tables out of the picture entirely.
    self.abstract_class = true
    include Wallets::Embeddable
    include Wallets::HasMetadata

    self.table_suffix = "transfers"

    class_attribute :transaction_class_name, default: "Wallets::Transaction"

    SUPPORTED_EXPIRATION_POLICIES = %w[preserve none fixed].freeze

    def self.transaction_class
      transaction_class_name.constantize
    end

    # Explicit `optional: false` because the gem's models load before Rails
    # applies `belongs_to_required_by_default`.
    belongs_to :from_wallet, class_name: "Wallets::Wallet", inverse_of: :outgoing_transfers, optional: false
    belongs_to :to_wallet, class_name: "Wallets::Wallet", inverse_of: :incoming_transfers, optional: false

    # When a transfer record goes away (e.g. one side's wallet or owner is
    # destroyed), the counterparty's ledger rows must survive: only the link
    # is cleared. The transaction metadata still carries `transfer_id` and the
    # counterparty details for audit purposes.
    has_many :transactions,
      class_name: "Wallets::Transaction",
      foreign_key: :transfer_id,
      inverse_of: :transfer,
      dependent: :nullify

    validates :asset_code, presence: true
    validates :amount, presence: true, numericality: {only_integer: true, greater_than: 0}
    validates :category, presence: true
    validates :expiration_policy, presence: true, inclusion: {in: SUPPORTED_EXPIRATION_POLICIES}
    validate :wallets_must_differ
    validate :wallet_assets_match_transfer_asset

    before_validation :normalize_asset_code!
    before_validation :normalize_expiration_policy!

    def outbound_transactions
      transfer_transactions_for(wallet_id: from_wallet_id).debits
    end

    def outbound_transaction
      outbound_transactions.order(:id).first
    end

    def inbound_transactions
      transfer_transactions_for(wallet_id: to_wallet_id).credits
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
      self.asset_code = Wallets.normalize_asset_code(asset_code).presence
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

    def transfer_transactions_for(wallet_id:)
      return transaction_class.none unless persisted? && wallet_id.present?

      transaction_class.where(transfer_id: id, wallet_id: wallet_id)
    end
  end

  # The concrete standalone ledger model (table: wallets_transfers via the
  # default config). Embedders subclass TransferBase instead.
  class Transfer < TransferBase
  end
end
