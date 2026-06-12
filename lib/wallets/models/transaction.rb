# frozen_string_literal: true

module Wallets
  # Transactions are the append-only source of truth for wallet balance changes.
  # Positive rows add value, negative rows consume value, and transfers link both
  # sides of an internal movement through `transfer_id`.
  #
  # This class supports embedding: subclasses can override config and table
  # names without affecting the base Wallets::* behavior.
  class Transaction < ApplicationRecord
    include Wallets::Embeddable
    include Wallets::HasMetadata

    self.table_suffix = "transactions"

    DEFAULT_CATEGORIES = [
      "credit",
      "debit",
      "transfer_in",
      "transfer_out",
      "refund",
      "reward",
      "purchase",
      "top_up",
      "adjustment"
    ].freeze
    CATEGORIES = DEFAULT_CATEGORIES

    def self.categories
      extra_categories =
        if resolved_config.respond_to?(:additional_categories)
          resolved_config.additional_categories
        else
          []
        end

      (DEFAULT_CATEGORIES + extra_categories).uniq
    end

    # Explicit `optional:` flags because the gem's models load before Rails
    # applies `belongs_to_required_by_default`.
    belongs_to :wallet, class_name: "Wallets::Wallet", optional: false
    belongs_to :transfer, class_name: "Wallets::Transfer", optional: true

    has_many :outgoing_allocations,
             class_name: "Wallets::Allocation",
             foreign_key: :transaction_id,
             dependent: :destroy

    has_many :incoming_allocations,
             class_name: "Wallets::Allocation",
             foreign_key: :source_transaction_id,
             dependent: :destroy

    validates :amount, presence: true, numericality: { only_integer: true }
    validates :category, presence: true, inclusion: { in: ->(record) { record.class.categories } }
    validate :remaining_amount_cannot_be_negative

    scope :credits, -> { where("amount > 0") }
    scope :debits, -> { where("amount < 0") }
    scope :recent, -> { order(created_at: :desc) }
    scope :by_category, ->(category) { where(category: category) }
    # `not_expired` and `expired` partition all transactions at any instant:
    # a transaction expiring exactly "now" is already expired, matching the
    # balance math, which only counts buckets that are strictly still alive.
    scope :not_expired, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at <= ?", Time.current) }

    def owner
      wallet.owner
    end

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def credit?
      amount.positive?
    end

    def debit?
      amount.negative?
    end

    def allocated_amount
      incoming_allocations.sum(:amount)
    end

    def spent_amount
      outgoing_allocations.sum(:amount)
    end

    def remaining_amount
      return 0 unless credit?

      amount - allocated_amount
    end

    def unbacked_amount
      return 0 unless debit?

      amount.abs - spent_amount
    end

    def balance_before
      metadata[:balance_before]
    end

    def balance_after
      metadata[:balance_after]
    end

    def sync_balance_snapshot!(before:, after:)
      update!(metadata: metadata.merge(
        balance_before: before,
        balance_after: after
      ))
    end

    private

    def remaining_amount_cannot_be_negative
      if credit? && remaining_amount.negative?
        errors.add(:base, "Allocated amount exceeds transaction amount")
      end
    end
  end
end
