# frozen_string_literal: true

module Wallets
  # Allocations link a negative spend transaction to the positive transactions it
  # consumed from. This is what makes FIFO spending and expiration-aware balances
  # possible without mutating historical transactions.
  class Allocation < ApplicationRecord
    def self.table_name
      "#{Wallets.configuration.table_prefix}allocations"
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
