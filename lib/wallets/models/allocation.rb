# frozen_string_literal: true

module Wallets
  # Allocations link a negative spend transaction to the positive transactions it
  # consumed from. This is what makes FIFO spending and expiration-aware balances
  # possible without mutating historical transactions.
  #
  # This class supports embedding: subclasses can override config and table
  # names without affecting the base Wallets::* behavior.
  class Allocation < ApplicationRecord
    class_attribute :embedded_table_name, default: nil
    class_attribute :config_provider, default: -> { Wallets.configuration }

    def self.table_name
      embedded_table_name || "#{resolved_config.table_prefix}allocations"
    end

    def self.resolved_config
      value = config_provider
      value.respond_to?(:call) ? value.call : value
    end

    belongs_to :spend_transaction, class_name: "Wallets::Transaction", foreign_key: "transaction_id"
    belongs_to :source_transaction, class_name: "Wallets::Transaction"

    validates :amount, presence: true, numericality: { only_integer: true, greater_than: 0 }
    validate :source_transaction_has_matching_asset
    validate :allocation_does_not_exceed_remaining_amount

    private

    def source_transaction_has_matching_asset
      return if spend_transaction.blank? || source_transaction.blank?
      return if spend_transaction.wallet_id == source_transaction.wallet_id

      errors.add(:source_transaction, "must belong to the same wallet as the spend transaction")
    end

    def allocation_does_not_exceed_remaining_amount
      return if amount.blank? || source_transaction.blank?

      if source_transaction.remaining_amount < amount
        errors.add(:amount, "exceeds the remaining amount of the source transaction")
      end
    end
  end
end
