# frozen_string_literal: true

module Wallets
  # Transactions are the append-only source of truth for wallet balance changes.
  # Positive rows add value, negative rows consume value, and transfers link both
  # sides of an internal movement through `transfer_id`.
  class Transaction < ApplicationRecord
    def self.table_name
      "#{Wallets.configuration.table_prefix}transactions"
    end

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

    belongs_to :wallet, class_name: "Wallets::Wallet"
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
    validates :category, presence: true, inclusion: { in: ->(_) { categories } }
    validate :remaining_amount_cannot_be_negative

    before_save :sync_metadata_cache

    scope :credits, -> { where("amount > 0") }
    scope :debits, -> { where("amount < 0") }
    scope :recent, -> { order(created_at: :desc) }
    scope :by_category, ->(category) { where(category: category) }
    scope :not_expired, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at < ?", Time.current) }

    def self.categories
      (DEFAULT_CATEGORIES + Wallets.configuration.additional_categories).uniq
    end

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

    def owner
      wallet.owner
    end

    def expired?
      expires_at.present? && expires_at < Time.current
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

    # When negative balances are allowed, a debit can exceed the currently
    # available positive buckets. The unmatched portion remains "unbacked".
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

    def sync_metadata_cache
      if @indifferent_metadata
        write_attribute(:metadata, @indifferent_metadata.to_h)
      elsif read_attribute(:metadata).nil?
        write_attribute(:metadata, {})
      end
    end

    def remaining_amount_cannot_be_negative
      if credit? && remaining_amount.negative?
        errors.add(:base, "Allocated amount exceeds transaction amount")
      end
    end
  end
end
