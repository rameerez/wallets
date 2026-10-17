# frozen_string_literal: true

module Wallets
  # Allocations link a negative spend transaction to the positive transactions it
  # consumed from. This makes expiration-aware spending and balances
  # possible without mutating historical transactions.
  #
  # This class supports embedding: subclasses can override config and table
  # names without affecting the base Wallets::* behavior.
  class AllocationBase < ApplicationRecord
    # Abstract on purpose: embedders (like usage_credits) subclass THIS
    # class, not the concrete Allocation below. ActiveRecord builds a
    # subclass's attribute methods on its parent's, so a concrete parent
    # forces a schema load of the wallets_* tables — which do not exist in
    # apps that only run an embedded ledger (fresh usage_credits installs).
    # An abstract parent makes each embedded subclass its own base_class
    # and keeps the base tables out of the picture entirely.
    self.abstract_class = true
    include Wallets::Embeddable

    self.table_suffix = "allocations"

    # Explicit `optional: false` because the gem's models load before Rails
    # applies `belongs_to_required_by_default`.
    belongs_to :spend_transaction, class_name: "Wallets::Transaction", foreign_key: "transaction_id", optional: false
    belongs_to :source_transaction, class_name: "Wallets::Transaction", optional: false

    validates :amount, presence: true, numericality: {only_integer: true, greater_than: 0}
    validate :source_transaction_has_matching_asset
    validate :spend_transaction_must_be_a_debit
    validate :source_transaction_must_be_a_credit
    validate :allocation_does_not_exceed_remaining_amount
    validate :allocation_does_not_exceed_unbacked_amount

    private

    def source_transaction_has_matching_asset
      return if spend_transaction.blank? || source_transaction.blank?
      return if spend_transaction.wallet_id == source_transaction.wallet_id

      errors.add(:source_transaction, "must belong to the same wallet as the spend transaction")
    end

    def allocation_does_not_exceed_remaining_amount
      return if amount.blank? || source_transaction.blank?

      remaining_amount = source_transaction.amount - source_transaction.incoming_allocations.where.not(id: id).sum(:amount)
      if remaining_amount < amount
        errors.add(:amount, "exceeds the remaining amount of the source transaction")
      end
    end

    def spend_transaction_must_be_a_debit
      return if spend_transaction.blank? || spend_transaction.debit?

      errors.add(:spend_transaction, "must be a debit transaction")
    end

    def source_transaction_must_be_a_credit
      return if source_transaction.blank? || source_transaction.credit?

      errors.add(:source_transaction, "must be a credit transaction")
    end

    def allocation_does_not_exceed_unbacked_amount
      return if amount.blank? || spend_transaction.blank? || !spend_transaction.debit?

      unbacked_amount = spend_transaction.amount.abs - spend_transaction.outgoing_allocations.where.not(id: id).sum(:amount)
      if unbacked_amount < amount
        errors.add(:amount, "exceeds the unbacked amount of the spend transaction")
      end
    end
  end

  # The concrete standalone ledger model (table: wallets_allocations via the
  # default config). Embedders subclass AllocationBase instead.
  class Allocation < AllocationBase
  end
end
