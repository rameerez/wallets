# frozen_string_literal: true

module Wallets
  # A hold keeps value in the ledger but out of the available balance, like a
  # deposit that has not cleared or a card charge that is still pending.
  # One table, three shapes:
  #
  # - a credit hold (`transaction_id` set, no amount) holds that credit's whole
  #   remaining value. Several holds on one credit are independent reasons;
  #   the credit is held while any of them is active and is counted once.
  # - a wallet hold (no `transaction_id`, no amount) holds every credit in the
  #   wallet, including credits received later.
  # - a reservation (no `transaction_id`, an amount) sets that much of the
  #   wallet's available value aside. Reservations add up, like pending card
  #   charges.
  #
  # A hold is active until it is released (`released_at`) or its deadline
  # passes (`releases_at`). Deadlines are computed, never swept, exactly like
  # `expires_at`: at the deadline itself the hold is already inactive.
  #
  # A row validates only what it can see on itself. Rules that span records
  # (the credit belongs to this wallet and still has value, the wallet can
  # fund a reservation) are enforced by the wallet's commands under the wallet
  # lock, where they cannot race.
  #
  # This class supports embedding: subclasses can override config and table
  # names without affecting the base Wallets::* behavior.
  class HoldBase < ApplicationRecord
    # Abstract on purpose: embedders (like usage_credits) subclass THIS
    # class, not the concrete Hold below. ActiveRecord builds a subclass's
    # attribute methods on its parent's, so a concrete parent forces a schema
    # load of the wallets_* tables — which do not exist in apps that only run
    # an embedded ledger. An abstract parent makes each embedded subclass its
    # own base_class and keeps the base tables out of the picture entirely.
    self.abstract_class = true
    include Wallets::Embeddable
    include Wallets::HasMetadata

    # Release facts live next to the creation facts, never over them.
    has_metadata_column :release_metadata

    self.table_suffix = "holds"

    # Explicit `optional:` flags because the gem's models load before Rails
    # applies `belongs_to_required_by_default`.
    belongs_to :wallet, class_name: "Wallets::Wallet", inverse_of: :holds, optional: false
    # Named `credit`, not `transaction`: Active Record defines `#transaction`
    # on every record and refuses an association that would shadow it. The
    # column keeps the ledger's `transaction_id` name, as allocations do.
    belongs_to :credit, class_name: "Wallets::Transaction", foreign_key: :transaction_id, inverse_of: :holds, optional: true
    belongs_to :capture_transaction, class_name: "Wallets::Transaction", inverse_of: :captured_reservation, optional: true

    validates :category, presence: true
    validate :amount_must_be_nil_or_a_positive_whole_number
    # A credit hold always holds the credit's whole remaining value: an amount
    # on it would raise the unanswerable "the same 40 or another 40?" question.
    validates :amount, absence: {message: "must be blank on a credit hold"}, if: :credit_scoped?

    # Only an ended reservation can name the debit it was captured into, so a
    # coverage hold can never carry a capture link.
    with_options if: :captured? do
      validates :transaction_id, absence: {message: "must be blank on a captured reservation"}
      validates :amount, presence: {message: "can't be blank on a captured reservation"}
      validates :released_at, presence: {message: "can't be blank on a captured reservation"}
    end

    before_validation :normalize_category!

    # Qualify predicates through Arel so these scopes stay composable when a
    # joined table also has `amount` or `transaction_id` columns.
    #
    # A hold whose deadline is exactly "now" is already inactive: the same
    # boundary `not_expired` and `expired` draw for transactions.
    scope :active, ->(at: Time.current) {
      where(arel_table[:released_at].eq(nil))
        .where(arel_table[:releases_at].eq(nil).or(arel_table[:releases_at].gt(at)))
    }
    scope :released, -> { where(arel_table[:released_at].not_eq(nil)) }
    scope :coverage, -> { where(arel_table[:amount].eq(nil)) }
    scope :reservations, -> { where(arel_table[:amount].not_eq(nil)) }
    scope :for_wallet_scope, -> { where(arel_table[:transaction_id].eq(nil)) }
    scope :credit_scoped, -> { where(arel_table[:transaction_id].not_eq(nil)) }

    def active?(at: Time.current)
      released_at.nil? && (releases_at.nil? || releases_at > at)
    end

    # Ended explicitly: released by hand or by a capture.
    def released?
      released_at.present?
    end

    # Ended by its deadline alone: inactive, yet never released.
    def lapsed?(at: Time.current)
      !released? && releases_at.present? && releases_at <= at
    end

    def captured?
      capture_transaction_id.present?
    end

    def reservation?
      !amount.nil?
    end

    def coverage?
      amount.nil?
    end

    def wallet_scoped?
      transaction_id.nil?
    end

    def credit_scoped?
      !wallet_scoped?
    end

    private

    def normalize_category!
      self.category = category.to_s.strip.presence
    end

    # Checked on the raw assigned value: the integer column casts "ten" and
    # Float::INFINITY to nil, which would silently turn a bad reservation
    # into a coverage hold.
    def amount_must_be_nil_or_a_positive_whole_number
      raw_amount = amount_before_type_cast
      return if raw_amount.nil?

      unless Wallets::WholeNumber.parse(raw_amount, name: "Amount", allow_string: true).positive?
        errors.add(:amount, :greater_than, count: 0)
      end
    rescue ArgumentError
      errors.add(:amount, :not_an_integer)
    end
  end

  # The concrete standalone hold model (table: wallets_holds via the default
  # config). Embedders subclass HoldBase instead.
  class Hold < HoldBase
  end
end
