# frozen_string_literal: true

module Wallets
  # Wallet is the owner-facing API for one asset balance.
  #
  # Balances are not maintained by incrementing a counter in place. Instead, the
  # wallet derives its current balance from transactions and allocations so it
  # can support FIFO consumption, expirations, transfers, and a durable audit
  # trail at the same time.
  #
  # This class supports embedding: subclasses can override config, callbacks,
  # table names, and related model classes without affecting the base Wallets::*
  # behavior in the same application.
  class Wallet < ApplicationRecord
    # =========================================
    # Embeddability Hooks
    # =========================================

    class_attribute :embedded_table_name, default: nil
    class_attribute :config_provider, default: -> { Wallets.configuration }
    class_attribute :callbacks_module, default: Wallets::Callbacks
    class_attribute :transaction_class_name, default: "Wallets::Transaction"
    class_attribute :allocation_class_name, default: "Wallets::Allocation"
    class_attribute :transfer_class_name, default: "Wallets::Transfer"
    class_attribute :callback_event_map, default: {
      credited: :balance_credited,
      debited: :balance_debited,
      insufficient: :insufficient_balance,
      low_balance: :low_balance_reached,
      depleted: :balance_depleted,
      transfer_completed: :transfer_completed
    }.freeze

    # =========================================
    # Table Name Resolution
    # =========================================

    def self.table_name
      embedded_table_name || "#{resolved_config.table_prefix}wallets"
    end

    def self.resolved_config
      value = config_provider
      value.respond_to?(:call) ? value.call : value
    end

    def self.transaction_class
      transaction_class_name.constantize
    end

    def self.allocation_class
      allocation_class_name.constantize
    end

    def self.transfer_class
      transfer_class_name.constantize
    end

    # =========================================
    # Associations & Validations
    # =========================================

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

    # =========================================
    # Class Methods
    # =========================================

    class << self
      def create_for_owner!(owner:, asset_code:, initial_balance: 0, metadata: {})
        initial_balance = normalize_initial_balance(initial_balance)
        asset_code = normalize_asset_code(asset_code)
        metadata = metadata.respond_to?(:to_h) ? metadata.to_h : {}

        existing_wallet = find_by(owner: owner, asset_code: asset_code)
        return existing_wallet if existing_wallet.present?

        transaction do
          wallet = create!(
            owner: owner,
            asset_code: asset_code,
            balance: 0,
            metadata: metadata
          )

          if initial_balance.positive?
            wallet.credit(initial_balance, **initial_balance_credit_attributes)
          end

          wallet
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
          wallet = find_by(owner: owner, asset_code: asset_code)
          raise error if wallet.nil?

          if record_conflict_due_to_existing_wallet?(error)
            wallet
          else
            raise error
          end
        end
      end

      private

      def initial_balance_credit_attributes
        {
          category: :adjustment,
          metadata: { reason: "initial_balance" }
        }
      end

      def normalize_initial_balance(value)
        return 0 if value.nil?
        raise ArgumentError, "Initial balance must be a whole number" unless value == value.to_i

        value = value.to_i
        raise ArgumentError, "Initial balance cannot be negative" if value.negative?

        value
      end

      def normalize_asset_code(value)
        value.to_s.strip.downcase.presence || raise(ArgumentError, "Asset code is required")
      end

      def record_conflict_due_to_existing_wallet?(error)
        return true if error.is_a?(ActiveRecord::RecordNotUnique)
        return false unless error.is_a?(ActiveRecord::RecordInvalid)

        error.record.errors.of_kind?(:asset_code, :taken)
      end
    end

    # =========================================
    # Metadata Handling
    # =========================================

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

    # =========================================
    # Balance & History
    # =========================================

    def balance
      current_balance
    end

    def current_balance
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

    # =========================================
    # Credit & Debit Operations
    # =========================================

    def credit(amount, metadata: {}, category: :credit, expires_at: nil, transfer: nil, **extra_transaction_attributes)
      metadata = normalize_metadata(metadata)

      with_lock do
        apply_credit(
          amount,
          metadata: metadata,
          category: category,
          expires_at: expires_at,
          transfer: transfer,
          extra_attributes: extra_transaction_attributes
        )
      end
    end

    def debit(amount, metadata: {}, category: :debit, transfer: nil, **extra_transaction_attributes)
      metadata = normalize_metadata(metadata)

      with_lock do
        apply_debit(
          amount,
          metadata: metadata,
          category: category,
          transfer: transfer,
          extra_attributes: extra_transaction_attributes
        )
      end
    end

    # =========================================
    # Transfers
    # =========================================

    def transfer_to(other_wallet, amount, category: :transfer, metadata: {}, expiration_policy: nil, expires_at: nil)
      raise InvalidTransfer, "Target wallet is required" if other_wallet.nil?
      raise InvalidTransfer, "Target wallet must be persisted" unless other_wallet.persisted?
      raise InvalidTransfer, "Cannot transfer to the same wallet" if other_wallet.id == id
      raise InvalidTransfer, "Wallet assets must match" unless asset_code == other_wallet.asset_code
      raise InvalidTransfer, "Wallet classes must match" unless other_wallet.class == self.class

      amount = normalize_positive_amount!(amount)
      metadata = normalize_metadata(metadata)
      resolved_policy, inbound_expires_at = resolve_transfer_expiration!(expiration_policy, expires_at)

      ActiveRecord::Base.transaction do
        lock_wallet_pair!(other_wallet)

        previous_balance = balance
        if amount > previous_balance
          dispatch_insufficient_balance!(amount, previous_balance, metadata)
          raise InsufficientBalance, "Insufficient balance (#{previous_balance} < #{amount})"
        end

        transfer = transfer_class.create!(
          from_wallet: self,
          to_wallet: other_wallet,
          asset_code: asset_code,
          amount: amount,
          category: category,
          expiration_policy: resolved_policy,
          metadata: metadata
        )

        shared_metadata = metadata.to_h.deep_stringify_keys.merge(
          "transfer_id" => transfer.id,
          "asset_code" => asset_code,
          "transfer_category" => category.to_s,
          "transfer_expiration_policy" => resolved_policy
        )

        outbound_transaction = apply_debit(
          amount,
          category: :transfer_out,
          metadata: shared_metadata.merge(
            "counterparty_wallet_id" => other_wallet.id,
            "counterparty_owner_id" => other_wallet.owner_id,
            "counterparty_owner_type" => other_wallet.owner_type
          ),
          transfer: transfer
        )

        build_transfer_inbound_credit_specs(
          transfer: transfer,
          outbound_transaction: outbound_transaction,
          amount: amount,
          expiration_policy: resolved_policy,
          expires_at: inbound_expires_at
        ).each do |spec|
          other_wallet.send(
            :apply_credit,
            spec[:amount],
            category: :transfer_in,
            metadata: shared_metadata.merge(
              "counterparty_wallet_id" => id,
              "counterparty_owner_id" => owner_id,
              "counterparty_owner_type" => owner_type
            ),
            expires_at: spec[:expires_at],
            transfer: transfer
          )
        end

        dispatch_callback(:transfer_completed,
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

    # =========================================
    # Config & Class Accessors (Instance)
    # =========================================

    def config
      self.class.resolved_config
    end

    def callbacks
      self.class.callbacks_module
    end

    def transaction_class
      self.class.transaction_class
    end

    def allocation_class
      self.class.allocation_class
    end

    def transfer_class
      self.class.transfer_class
    end

    # =========================================
    # Callback Dispatching
    # =========================================

    def dispatch_callback(kind, **data)
      event = self.class.callback_event_map[kind]
      return if event.nil?

      callbacks.dispatch(event, **data)
    end

    # =========================================
    # Credit/Debit Implementation
    # =========================================

    def apply_credit(amount, metadata:, category:, expires_at:, transfer:, extra_attributes: {})
      amount = normalize_positive_amount!(amount)
      validate_expiration!(expires_at)

      previous_balance = balance

      transaction = transactions.create!(
        {
          amount: amount,
          category: category,
          expires_at: expires_at,
          metadata: metadata,
          transfer: transfer
        }.merge(extra_attributes)
      )

      refresh_cached_balance!
      transaction.sync_balance_snapshot!(before: previous_balance, after: balance)

      dispatch_callback(:credited,
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

    def apply_debit(amount, metadata:, category:, transfer:, extra_attributes: {})
      amount = normalize_positive_amount!(amount)
      previous_balance = balance

      if amount > previous_balance && !allow_negative_balance?
        dispatch_insufficient_balance!(amount, previous_balance, metadata)
        raise InsufficientBalance, "Insufficient balance (#{previous_balance} < #{amount})"
      end

      spend_transaction = transactions.create!(
        {
          amount: -amount,
          category: category,
          metadata: metadata,
          transfer: transfer
        }.merge(extra_attributes)
      )

      remaining_to_allocate = allocate_debit!(spend_transaction, amount)

      if remaining_to_allocate.positive? && !allow_negative_balance?
        raise InsufficientBalance, "Not enough balance buckets to cover the debit"
      end

      refresh_cached_balance!
      spend_transaction.sync_balance_snapshot!(before: previous_balance, after: balance)

      dispatch_callback(:debited,
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

        allocation_class.create!(
          spend_transaction: spend_transaction,
          source_transaction: source_transaction,
          amount: allocation_amount
        )

        remaining_to_allocate -= allocation_amount
        break if remaining_to_allocate <= 0
      end

      remaining_to_allocate
    end

    # =========================================
    # Transfer Expiration Handling
    # =========================================

    def resolve_transfer_expiration!(expiration_policy, expires_at)
      default_policy =
        if config.respond_to?(:transfer_expiration_policy)
          config.transfer_expiration_policy
        else
          :preserve
        end

      policy =
        if expires_at.present? && expiration_policy.nil?
          "fixed"
        else
          normalize_transfer_expiration_policy(expiration_policy || default_policy)
        end

      case policy
      when "preserve", "none"
        raise ArgumentError, "expires_at cannot be combined with #{policy} transfer expiration policy" if expires_at.present?
        [policy, nil]
      when "fixed"
        raise ArgumentError, "expires_at is required when using a fixed transfer expiration policy" if expires_at.nil?

        validate_expiration!(expires_at)
        [policy, expires_at]
      else
        raise ArgumentError, "Unsupported transfer expiration policy: #{policy}"
      end
    end

    def normalize_transfer_expiration_policy(value)
      value.to_s.strip.downcase
    end

    def build_transfer_inbound_credit_specs(transfer:, outbound_transaction:, amount:, expiration_policy:, expires_at:)
      case expiration_policy
      when "none"
        [{ amount: amount, expires_at: nil }]
      when "fixed"
        [{ amount: amount, expires_at: expires_at }]
      when "preserve"
        build_preserved_transfer_inbound_credit_specs(transfer, outbound_transaction, amount)
      else
        raise ArgumentError, "Unsupported transfer expiration policy: #{expiration_policy}"
      end
    end

    def build_preserved_transfer_inbound_credit_specs(transfer, outbound_transaction, amount)
      allocations = outbound_transaction.outgoing_allocations.includes(:source_transaction).order(:id).to_a
      grouped_specs = []

      allocations.each do |allocation|
        expires_at = allocation.source_transaction.expires_at

        if grouped_specs.last && grouped_specs.last[:expires_at] == expires_at
          grouped_specs.last[:amount] += allocation.amount
        else
          grouped_specs << { amount: allocation.amount, expires_at: expires_at }
        end
      end

      total_preserved_amount = grouped_specs.sum { |spec| spec[:amount] }
      if total_preserved_amount != amount
        raise InvalidTransfer, "Transfer #{transfer.id} could not preserve expiration buckets (#{total_preserved_amount} != #{amount})"
      end

      grouped_specs
    end

    # =========================================
    # Balance Calculation
    # =========================================

    def positive_remaining_balance
      txn_table = transaction_class.table_name
      alloc_table = allocation_class.table_name

      transactions
        .where("amount > 0")
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
        .sum("amount - (SELECT COALESCE(SUM(amount), 0) FROM #{alloc_table} WHERE source_transaction_id = #{txn_table}.id)")
        .to_i
    end

    def unbacked_negative_balance
      txn_table = transaction_class.table_name
      alloc_table = allocation_class.table_name

      transactions
        .where("amount < 0")
        .sum("ABS(amount) - (SELECT COALESCE(SUM(amount), 0) FROM #{alloc_table} WHERE transaction_id = #{txn_table}.id)")
        .to_i
    end

    def refresh_cached_balance!
      write_attribute(:balance, current_balance)
      save!
    end

    # =========================================
    # Threshold Callbacks
    # =========================================

    def dispatch_insufficient_balance!(amount, previous_balance, metadata)
      dispatch_callback(:insufficient,
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
        dispatch_callback(:low_balance,
          wallet: self,
          threshold: config.low_balance_threshold,
          previous_balance: previous_balance,
          new_balance: balance
        )
      end

      if previous_balance.positive? && balance.zero?
        dispatch_callback(:depleted,
          wallet: self,
          previous_balance: previous_balance,
          new_balance: 0
        )
      end
    end

    def low_balance?
      threshold = config.low_balance_threshold
      return false if threshold.nil?

      balance <= threshold
    end

    def was_low_balance?(previous_balance)
      threshold = config.low_balance_threshold
      return false if threshold.nil?

      previous_balance <= threshold
    end

    def allow_negative_balance?
      config.allow_negative_balance
    end

    # =========================================
    # Validation Helpers
    # =========================================

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
