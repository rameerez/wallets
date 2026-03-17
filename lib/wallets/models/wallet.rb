# frozen_string_literal: true

module Wallets
  # Wallet is the owner-facing API for one asset balance.
  #
  # Balances are not maintained by incrementing a counter in place. Instead, the
  # wallet derives its current balance from transactions and allocations so it
  # can support FIFO consumption, expirations, transfers, and a durable audit
  # trail at the same time.
  class Wallet < ApplicationRecord
    def self.table_name
      "#{Wallets.configuration.table_prefix}wallets"
    end

    belongs_to :owner, polymorphic: true

    has_many :transactions, class_name: "Wallets::Transaction", dependent: :destroy
    has_many :outgoing_transfers,
             class_name: "Wallets::Transfer",
             foreign_key: :from_wallet_id,
             dependent: :destroy,
             inverse_of: :from_wallet
    has_many :incoming_transfers,
             class_name: "Wallets::Transfer",
             foreign_key: :to_wallet_id,
             dependent: :destroy,
             inverse_of: :to_wallet

    validates :asset_code, presence: true, uniqueness: { scope: [:owner_type, :owner_id] }
    validates :balance, numericality: { only_integer: true }
    validates :balance, numericality: { greater_than_or_equal_to: 0 }, unless: :allow_negative_balance?

    before_validation :normalize_asset_code!
    before_save :sync_metadata_cache

    class << self
      def create_for_owner!(owner:, asset_code:, initial_balance: 0, metadata: {})
        initial_balance = normalize_initial_balance(initial_balance)
        metadata = metadata.respond_to?(:to_h) ? metadata.to_h : {}

        transaction do
          wallet = create!(
            owner: owner,
            asset_code: asset_code,
            balance: 0,
            metadata: metadata
          )

          if initial_balance.to_i.positive?
            wallet.credit(
              initial_balance,
              category: :adjustment,
              metadata: { reason: "initial_balance" }
            )
          end

          wallet
        end
      end

      private

      def normalize_initial_balance(value)
        return 0 if value.nil?
        raise ArgumentError, "Initial balance must be a whole number" unless value == value.to_i

        value = value.to_i
        raise ArgumentError, "Initial balance cannot be negative" if value.negative?

        value
      end
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

    def balance
      current_balance
    end

    def current_balance
      # Available balance is the unspent, unexpired value minus any debit that
      # was allowed to go negative and therefore could not be backed yet.
      positive_remaining_balance - unbacked_negative_balance
    end

    def history
      transactions.order(created_at: :asc)
    end

    def has_enough_balance?(amount)
      normalized_amount = normalize_positive_amount!(amount)
      balance >= normalized_amount
    rescue ArgumentError
      false
    end

    def credit(amount, metadata: {}, category: :credit, expires_at: nil, transfer: nil)
      metadata = normalize_metadata(metadata)

      with_lock do
        apply_credit(
          amount,
          metadata: metadata,
          category: category,
          expires_at: expires_at,
          transfer: transfer
        )
      end
    end

    def debit(amount, metadata: {}, category: :debit, transfer: nil)
      metadata = normalize_metadata(metadata)

      with_lock do
        apply_debit(
          amount,
          metadata: metadata,
          category: category,
          transfer: transfer
        )
      end
    end

    def transfer_to(other_wallet, amount, category: :transfer, metadata: {})
      raise InvalidTransfer, "Target wallet is required" if other_wallet.nil?
      raise InvalidTransfer, "Target wallet must be persisted" unless other_wallet.persisted?
      raise InvalidTransfer, "Cannot transfer to the same wallet" if other_wallet.id == id
      raise InvalidTransfer, "Wallet assets must match" unless asset_code == other_wallet.asset_code

      amount = normalize_positive_amount!(amount)
      metadata = normalize_metadata(metadata)

      ActiveRecord::Base.transaction do
        lock_wallet_pair!(other_wallet)

        transfer = Wallets::Transfer.create!(
          from_wallet: self,
          to_wallet: other_wallet,
          asset_code: asset_code,
          amount: amount,
          category: category,
          metadata: metadata
        )

        shared_metadata = metadata.to_h.deep_stringify_keys.merge(
          "transfer_id" => transfer.id,
          "asset_code" => asset_code,
          "counterparty_wallet_id" => other_wallet.id,
          "counterparty_owner_id" => other_wallet.owner_id,
          "counterparty_owner_type" => other_wallet.owner_type
        )

        outbound_transaction = apply_debit(
          amount,
          category: :transfer_out,
          metadata: shared_metadata.merge("transfer_category" => category.to_s),
          transfer: transfer
        )

        inbound_transaction = other_wallet.send(
          :apply_credit,
          amount,
          category: :transfer_in,
          metadata: shared_metadata.merge(
            "counterparty_wallet_id" => id,
            "counterparty_owner_id" => owner_id,
            "counterparty_owner_type" => owner_type,
            "transfer_category" => category.to_s
          ),
          expires_at: nil,
          transfer: transfer
        )

        transfer.update!(
          outbound_transaction: outbound_transaction,
          inbound_transaction: inbound_transaction
        )

        Wallets::Callbacks.dispatch(
          :transfer_completed,
          wallet: self,
          transfer: transfer,
          amount: amount,
          category: category,
          metadata: metadata
        )

        transfer
      end
    end

    private

    def apply_credit(amount, metadata:, category:, expires_at:, transfer:)
      amount = normalize_positive_amount!(amount)
      validate_expiration!(expires_at)

      previous_balance = balance

      transaction = transactions.create!(
        amount: amount,
        category: category,
        expires_at: expires_at,
        metadata: metadata,
        transfer: transfer
      )

      refresh_cached_balance!
      transaction.sync_balance_snapshot!(before: previous_balance, after: balance)

      Wallets::Callbacks.dispatch(
        :balance_credited,
        wallet: self,
        amount: amount,
        category: category,
        transaction: transaction,
        previous_balance: previous_balance,
        new_balance: balance,
        metadata: metadata
      )

      transaction
    end

    def apply_debit(amount, metadata:, category:, transfer:)
      amount = normalize_positive_amount!(amount)
      previous_balance = balance

      if amount > previous_balance && !allow_negative_balance?
        dispatch_insufficient_balance!(amount, previous_balance, metadata)
        raise InsufficientBalance, "Insufficient balance (#{previous_balance} < #{amount})"
      end

      spend_transaction = transactions.create!(
        amount: -amount,
        category: category,
        metadata: metadata,
        transfer: transfer
      )

      remaining_to_allocate = allocate_debit!(spend_transaction, amount)

      if remaining_to_allocate.positive? && !allow_negative_balance?
        raise InsufficientBalance, "Not enough balance buckets to cover the debit"
      end

      refresh_cached_balance!
      spend_transaction.sync_balance_snapshot!(before: previous_balance, after: balance)

      Wallets::Callbacks.dispatch(
        :balance_debited,
        wallet: self,
        amount: amount,
        category: category,
        transaction: spend_transaction,
        previous_balance: previous_balance,
        new_balance: balance,
        metadata: metadata
      )

      dispatch_balance_threshold_callbacks!(previous_balance)

      spend_transaction
    end

    def allocate_debit!(spend_transaction, amount)
      remaining_to_allocate = amount

      # Spend the oldest available buckets first so expiring value is consumed
      # before evergreen value when both are present.
      positive_transactions = transactions
        .where("amount > 0")
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
        .order(Arel.sql("COALESCE(expires_at, '9999-12-31 23:59:59'), id ASC"))
        .lock("FOR UPDATE")
        .to_a

      positive_transactions.each do |source_transaction|
        leftover = source_transaction.remaining_amount
        next if leftover <= 0

        allocation_amount = [leftover, remaining_to_allocate].min

        Allocation.create!(
          spend_transaction: spend_transaction,
          source_transaction: source_transaction,
          amount: allocation_amount
        )

        remaining_to_allocate -= allocation_amount
        break if remaining_to_allocate <= 0
      end

      remaining_to_allocate
    end

    def positive_remaining_balance
      transactions_table = Wallets::Transaction.table_name
      allocations_table = Wallets::Allocation.table_name

      # Summing remaining positive buckets is more accurate than summing raw
      # transaction amounts once expirations and partial consumption exist.
      transactions
        .where("amount > 0")
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
        .sum("amount - (SELECT COALESCE(SUM(amount), 0) FROM #{allocations_table} WHERE source_transaction_id = #{transactions_table}.id)")
        .to_i
    end

    def unbacked_negative_balance
      transactions_table = Wallets::Transaction.table_name
      allocations_table = Wallets::Allocation.table_name

      # Negative balances are represented as debits whose full amount could not
      # be matched to positive source buckets at the time of spending.
      transactions
        .where("amount < 0")
        .sum("ABS(amount) - (SELECT COALESCE(SUM(amount), 0) FROM #{allocations_table} WHERE transaction_id = #{transactions_table}.id)")
        .to_i
    end

    def refresh_cached_balance!
      write_attribute(:balance, current_balance)
      save!
    end

    def dispatch_insufficient_balance!(amount, previous_balance, metadata)
      Wallets::Callbacks.dispatch(
        :insufficient_balance,
        wallet: self,
        amount: amount,
        previous_balance: previous_balance,
        new_balance: previous_balance,
        metadata: metadata.merge(
          available: previous_balance,
          required: amount
        )
      )
    end

    def dispatch_balance_threshold_callbacks!(previous_balance)
      if !was_low_balance?(previous_balance) && low_balance?
        Wallets::Callbacks.dispatch(
          :low_balance_reached,
          wallet: self,
          threshold: Wallets.configuration.low_balance_threshold,
          previous_balance: previous_balance,
          new_balance: balance
        )
      end

      if previous_balance.positive? && balance.zero?
        Wallets::Callbacks.dispatch(
          :balance_depleted,
          wallet: self,
          previous_balance: previous_balance,
          new_balance: 0
        )
      end
    end

    def low_balance?
      threshold = Wallets.configuration.low_balance_threshold
      return false if threshold.nil?

      balance <= threshold
    end

    def was_low_balance?(previous_balance)
      threshold = Wallets.configuration.low_balance_threshold
      return false if threshold.nil?

      previous_balance <= threshold
    end

    def allow_negative_balance?
      Wallets.configuration.allow_negative_balance
    end

    def validate_expiration!(expires_at)
      return if expires_at.nil?
      raise ArgumentError, "Expiration date must respond to to_datetime" unless expires_at.respond_to?(:to_datetime)
      raise ArgumentError, "Expiration date must be in the future" if expires_at <= Time.current
    end

    def normalize_positive_amount!(amount)
      raise ArgumentError, "Amount is required" if amount.nil?
      raise ArgumentError, "Amount must be a whole number" unless amount == amount.to_i

      amount = amount.to_i
      raise ArgumentError, "Amount must be positive" unless amount.positive?

      amount
    end

    def normalize_metadata(metadata)
      metadata.respond_to?(:to_h) ? metadata.to_h : {}
    end

    def lock_wallet_pair!(other_wallet)
      # Lock in a stable order so concurrent transfers do not deadlock.
      first, second = [self, other_wallet].sort_by(&:id)
      first.lock!
      second.lock! unless first.id == second.id
    end

    def normalize_asset_code!
      self.asset_code = asset_code.to_s.strip.downcase.presence
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
