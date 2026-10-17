# frozen_string_literal: true

module Wallets
  # Wallet is the owner-facing API for one asset balance.
  #
  # Balances are not maintained by incrementing a counter in place. Instead, the
  # wallet derives its current balance from transactions and allocations so it
  # can support expiration-aware consumption, transfers, and a durable audit
  # trail at the same time.
  #
  # `balance` is the AVAILABLE balance: what can be spent right now. Holds keep
  # value in the ledger but out of it, exactly the way expiry already does:
  #
  #   balance (available) = P - C - R - N
  #   held_balance        = C + R
  #   total_balance       = P - N
  #
  # P is the remaining value of unexpired credits, C the part of P an active
  # hold covers, R the active reservations, and N the debt no credit backs.
  # Without holds, C and R are zero and nothing changes.
  #
  # This class supports embedding: subclasses can override config, callbacks,
  # table names, and related model classes without affecting the base Wallets::*
  # behavior in the same application.
  class WalletBase < ApplicationRecord
    # Abstract on purpose: embedders (like usage_credits) subclass THIS
    # class, not the concrete Wallet below. ActiveRecord builds a
    # subclass's attribute methods on its parent's, so a concrete parent
    # forces a schema load of the wallets_* tables — which do not exist in
    # apps that only run an embedded ledger (fresh usage_credits installs).
    # An abstract parent makes each embedded subclass its own base_class
    # and keeps the base tables out of the picture entirely.
    self.abstract_class = true
    include Wallets::Embeddable
    include Wallets::HasMetadata

    CORE_TRANSACTION_ATTRIBUTE_NAMES = %i[
      id wallet wallet_id amount category expires_at metadata transfer
      transfer_id balance_before balance_after created_at updated_at
    ].freeze

    # Plain SELECTs on these adapters may answer from a stale snapshot inside
    # a transaction (see `current_reads_need_locks?`).
    SNAPSHOT_READ_ADAPTERS = /mysql|trilogy/i
    private_constant :SNAPSHOT_READ_ADAPTERS

    self.table_suffix = "wallets"

    # =========================================
    # Embeddability Hooks
    # =========================================

    class_attribute :callbacks_module, default: Wallets::Callbacks
    class_attribute :transaction_class_name, default: "Wallets::Transaction"
    class_attribute :allocation_class_name, default: "Wallets::Allocation"
    class_attribute :transfer_class_name, default: "Wallets::Transfer"
    # Holds are opt-in per ledger. nil keeps a ledger exactly as it was before
    # holds existed: no hold SQL anywhere, destroy included. The concrete
    # Wallet below opts in; an embedder opts in deliberately, with its own hold
    # class, table and balance policy. Never inferred from a table's existence:
    # an enabled ledger with a missing table must fail loudly, not quietly
    # make held value spendable.
    class_attribute :hold_class_name, default: nil
    # Embedded ledgers may add their own transaction columns (for example,
    # usage_credits adds `fulfillment_id`). Keeping an explicit allowlist
    # prevents arbitrary keyword attributes from overriding accounting fields
    # such as amount, wallet, category, metadata, or timestamps.
    class_attribute :additional_transaction_attribute_names, default: [].freeze
    class_attribute :callback_event_map, default: {
      credited: :balance_credited,
      debited: :balance_debited,
      insufficient: :insufficient_balance,
      low_balance: :low_balance_reached,
      depleted: :balance_depleted,
      transfer_completed: :transfer_completed
    }.freeze

    def self.transaction_class
      transaction_class_name.constantize
    end

    def self.allocation_class
      allocation_class_name.constantize
    end

    def self.transfer_class
      transfer_class_name.constantize
    end

    def self.hold_class
      raise HoldsNotEnabled, "#{name} does not keep holds (its hold_class_name is nil)" unless holds_enabled?

      hold_class_name.constantize
    end

    def self.holds_enabled?
      hold_class_name.present?
    end

    # Whether this database can answer a plain read from a stale snapshot, so
    # that a mutation may need locking reads to see the ledger as it is now.
    # Under MySQL's (and MariaDB's) default repeatable read, a transaction's
    # consistent snapshot is fixed by its FIRST plain read: a caller that read
    # anything before calling a wallet command keeps that snapshot after the
    # wallet lock is granted, and a plain SUM would miss what the previous
    # lock holder committed. Locking reads always read the latest committed
    # rows. PostgreSQL's default read committed takes a fresh snapshot per
    # statement (and refuses FOR UPDATE beside an aggregate), and SQLite
    # serializes writers, so both already read current rows. Whether a given
    # mutation actually needs locking reads is `stale_snapshot?`.
    def self.current_reads_need_locks?
      transaction_class.connection.adapter_name.match?(SNAPSHOT_READ_ADAPTERS)
    end

    # One definition of "held" for credits, shared by `held_balance`, FEFO
    # eligibility and `Transaction#held?`, so the three can never disagree.
    # SQL that is true for a credit row of this ledger that an active hold
    # covers at `at`: a hold on that very credit, or a hold on its whole
    # wallet. Correlated EXISTS, never a join, so a credit held for two
    # reasons still counts once.
    def self.coverage_sql(at:, lock: false)
      holds = hold_class.arel_table
      credits = transaction_class.arel_table
      active_holds = hold_class.active(at: at).select(Arel.sql("1"))
      active_holds = active_holds.lock("FOR UPDATE") if lock && current_reads_need_locks?

      credit_holds = active_holds.where(holds[:transaction_id].eq(credits[:id]))
      wallet_holds = active_holds.coverage.for_wallet_scope.where(holds[:wallet_id].eq(credits[:wallet_id]))

      "(EXISTS (#{credit_holds.to_sql}) OR EXISTS (#{wallet_holds.to_sql}))"
    end

    # =========================================
    # Associations & Validations
    # =========================================

    # `optional: false` is explicit everywhere because the gem's models load
    # before Rails applies `belongs_to_required_by_default`, so the host app's
    # default never reaches these associations.
    belongs_to :owner, polymorphic: true, optional: false

    # foreign_key is explicit because this association is declared on the
    # abstract WalletBase: ActiveRecord would otherwise derive it from the
    # declaring class name ("wallet_base_id").
    has_many :transactions, class_name: "Wallets::Transaction", foreign_key: :wallet_id, inverse_of: :wallet, dependent: :destroy
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

    validates :asset_code, presence: true, uniqueness: {scope: [:owner_type, :owner_id]}
    # Signed on purpose: available balance can drop below zero without any
    # overdraft (reserve 80 of 100, then a fraud hold covers the 100; or
    # reserved value expires). A save-time floor would reject the very hold,
    # release or incoming credit that follows. Commands enforce funding under
    # the wallet lock instead.
    validates :balance, numericality: {only_integer: true}

    before_validation :normalize_asset_code!

    # =========================================
    # Class Methods
    # =========================================

    class << self
      def create_for_owner!(owner:, asset_code:, initial_balance: 0, metadata: {})
        initial_balance = normalize_initial_balance(initial_balance)
        asset_code = normalize_asset_code(asset_code)

        existing_wallet = find_by(owner: owner, asset_code: asset_code)
        return existing_wallet if existing_wallet.present?

        # `requires_new` gives us a savepoint when we are already inside a
        # caller's transaction (e.g. `after_create` wallet auto-creation), and
        # the rescue lives OUTSIDE the transaction block. Both matter on
        # PostgreSQL: a concurrent duplicate INSERT aborts the transaction it
        # ran in, so recovering with a SELECT only works after that
        # transaction (or savepoint) has rolled back.
        begin
          transaction(requires_new: true) do
            wallet = create!(
              owner: owner,
              asset_code: asset_code,
              balance: 0,
              metadata: metadata
            )

            wallet.credit(initial_balance, **initial_balance_credit_attributes) if initial_balance.positive?

            wallet
          end
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
          raise error unless record_conflict_due_to_existing_wallet?(error)

          # Two callers raced to create the same wallet; the loser gracefully
          # returns the winner's row.
          find_by(owner: owner, asset_code: asset_code) || raise(error)
        end
      end

      private

      def initial_balance_credit_attributes
        {
          category: :adjustment,
          metadata: {reason: "initial_balance"}
        }
      end

      def normalize_initial_balance(value)
        return 0 if value.nil?

        value = Wallets::WholeNumber.parse(value, name: "Initial balance")
        raise ArgumentError, "Initial balance cannot be negative" if value.negative?

        value
      end

      def normalize_asset_code(value)
        Wallets.normalize_asset_code(value).presence || raise(ArgumentError, "Asset code is required")
      end

      def record_conflict_due_to_existing_wallet?(error)
        return true if error.is_a?(ActiveRecord::RecordNotUnique)

        error.record.errors.of_kind?(:asset_code, :taken)
      end
    end

    # =========================================
    # Balance & History
    # =========================================

    # The available balance: what can be spent right now. Held, reserved and
    # expired value is excluded.
    def balance
      current_balance
    end

    def current_balance
      at = evaluation_time

      positive_remaining_balance(at: at) -
        covered_remaining_balance(at: at) -
        reserved_balance(at: at) -
        unbacked_negative_balance
    end

    def available_balance
      balance
    end

    # Value in the ledger that holds keep out of `balance`: held credits plus
    # active reservations. It can exceed `total_balance` (a hold over value
    # that is already reserved, or reservations whose backing expired), and is
    # deliberately not capped.
    def held_balance
      return 0 unless holds_enabled?

      at = evaluation_time
      covered_remaining_balance(at: at) + reserved_balance(at: at)
    end

    # Everything the ledger holds for the owner, spendable or not. Defined as
    # available plus held at one instant, so the identity holds by
    # construction, even for an embedder whose `current_balance` applies its
    # own policy (and, without holds, it is simply `balance`).
    def total_balance
      evaluating_at(evaluation_time) { balance + held_balance }
    end

    # Whether a hold covers the whole wallet, including credits received
    # later. A pending reservation is not a blanket hold.
    def on_hold?
      return false unless holds_enabled?

      wallet_holds.coverage.for_wallet_scope.active(at: evaluation_time).exists?
    end

    def holds_enabled?
      self.class.holds_enabled?
    end

    def history
      transactions.order(created_at: :asc, id: :asc)
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
      extra_transaction_attributes = validate_additional_transaction_attributes!(extra_transaction_attributes)

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
      extra_transaction_attributes = validate_additional_transaction_attributes!(extra_transaction_attributes)

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
      raise InvalidTransfer, "Source wallet must be persisted" unless persisted?
      raise InvalidTransfer, "Target wallet must be persisted" unless other_wallet.persisted?
      raise InvalidTransfer, "Cannot transfer to the same wallet" if other_wallet.id == id
      raise InvalidTransfer, "Wallet assets must match" unless asset_code == other_wallet.asset_code
      raise InvalidTransfer, "Wallet classes must match" unless other_wallet.instance_of?(self.class)

      amount = normalize_positive_amount!(amount)
      metadata = normalize_metadata(metadata)
      resolved_policy, inbound_expires_at = resolve_transfer_expiration!(expiration_policy, expires_at)

      self.class.transaction do
        lock_wallet_pair!(other_wallet)
        now = Time.current

        # The recipient pins the same instant in its own `apply_credit`.
        mutating_at(now) do
          previous_balance = balance

          # Insufficient-balance gate.
          #
          # `allow_negative_balance` is the single source of truth for whether
          # the gem permits a wallet to drop below zero. Direct `wallet.debit`
          # has always honored it via `apply_debit`; transfers must too, or
          # the flag is half-applied and surprising (debits go through, the
          # canonical transfer primitive doesn't).
          #
          # When the flag is OFF, this is the only chance to refuse cleanly:
          # we want to dispatch `:insufficient_balance` for the observability
          # callback, then raise BEFORE creating the Transfer row. (The later
          # `apply_debit` call would also catch this, but only after a
          # pointless Transfer row was created.)
          #
          # When the flag is ON, we let the transfer through. `apply_debit`
          # below will allocate as many eligible buckets as exist; the
          # remaining shortfall lands as an unbacked negative transaction the
          # wallet's `balance` accounting accommodates via
          # `unbacked_negative_balance`.
          if amount > previous_balance && !allow_negative_balance?
            reject_insufficient_balance!(amount, previous_balance, metadata)
          end

          # `:preserve` gives each inbound credit the expiration of the source
          # bucket it was allocated from. A portion of the outbound debit that
          # no bucket backs has no source expiration to preserve, and
          # `build_preserved_transfer_inbound_credit_specs` would refuse with
          # `InvalidTransfer` on the count mismatch, defeating the very callers
          # who opted into negative balances. The only honest fallback is to
          # collapse the inbound side to a single evergreen credit (`:none`):
          # value created without a source bucket has no source expiration.
          #
          # The fallback is decided by what allocation will actually back,
          # never by the available balance. Available also nets out
          # reservations and earlier debt, so a transfer can exceed it while
          # FEFO still backs every unit from eligible buckets (a reservation
          # outstanding, or old debt followed by fresh credits); such a
          # transfer keeps its source expirations. `eligible_remaining_balance`
          # sums exactly the buckets `allocate_debit!` walks, at this instant
          # and under these locks, so it is the outcome, not an estimate.
          #
          # Callers who care about a specific expiration on the inbound side
          # should pass `expiration_policy: :fixed, expires_at: …`. Those are
          # honored unchanged because they don't depend on source-bucket
          # walking. Same for an explicit `:none`.
          if resolved_policy == "preserve" && amount > eligible_remaining_balance
            resolved_policy = "none"
            inbound_expires_at = nil
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
              transfer: transfer,
              at: now
            )
          end

          dispatch_callback(:transfer_completed,
            wallet: self,
            transfer: transfer,
            amount: amount,
            category: category,
            metadata: metadata)

          transfer
        end
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

    def hold_class
      self.class.hold_class
    end

    # =========================================
    # Callback Dispatching
    # =========================================

    def dispatch_callback(kind, **data)
      event = self.class.callback_event_map[kind]
      return if event.nil?

      callback_dispatcher = callbacks
      dispatch = -> { callback_dispatcher.dispatch(event, **data) }

      # Successful ledger callbacks describe committed facts. Deferring them
      # through the outermost transaction prevents notifications/jobs for rows
      # that a caller later rolls back. Failure callbacks are intentionally
      # immediate because their transaction is about to roll back by design.
      if kind == :insufficient || !ActiveRecord.respond_to?(:after_all_transactions_commit)
        dispatch.call
      else
        ActiveRecord.after_all_transactions_commit(&dispatch)
      end
    end

    # =========================================
    # Evaluation Instant
    # =========================================

    # A mutation decides on several accounting reads: affordability, FEFO
    # eligibility, the cached balance, snapshots and callbacks. They must all
    # describe one instant (a credit expiring or a hold lapsing between two of
    # them would make the operation contradict itself) and the rows as they
    # are now, not as an older snapshot saw them. `evaluating_at` pins both for
    # the block, and every balance read inside it picks them up, including an
    # embedder's own `current_balance` that calls the helpers without
    # arguments. The first pin wins, so a nested mutation keeps its caller's
    # instant.
    def evaluating_at(time, current_reads: false)
      return yield if @evaluation_time

      @evaluation_time = time
      @current_reads = current_reads
      begin
        yield
      ensure
        @evaluation_time = @current_reads = nil
      end
    end

    # The pin a mutation takes once the wallet lock is held: one instant, and
    # current reads exactly when this transaction's snapshot is stale.
    def mutating_at(time, &block)
      return yield if @evaluation_time

      evaluating_at(time, current_reads: stale_snapshot?, &block)
    end

    def evaluation_time
      @evaluation_time || Time.current
    end

    def current_reads?
      @current_reads == true
    end

    # Whether this mutation must use locking reads to see the current ledger.
    # Called with the wallet lock held.
    #
    # Only when this transaction's snapshot is stale for this wallet: every
    # command bumps the wallet row under its lock (`refresh_cached_balance!`),
    # so when the row this transaction's snapshot shows is the row the lock
    # returned, nothing was committed to this wallet's ledger after the
    # snapshot and plain reads already see it as it is now. That covers every
    # command that runs first in its transaction, or in a transaction that
    # created the wallet, or that read before taking the lock without anyone
    # writing in between.
    #
    # Locking reads everywhere would be correct but not safe to run: InnoDB
    # takes gap locks on the ranges they scan, and the gaps after a wallet's
    # newest rows are the very gaps OTHER wallets insert into, so unrelated
    # concurrent debits or sign-ups deadlock each other (a tenth of them in a
    # stress run). Kept to the stale case, which needs a caller that read
    # first AND a concurrent change to this same wallet, they are rare.
    #
    # A stale verdict is remembered until the transaction ends: once this
    # transaction writes the wallet row, its snapshot shows its own write and
    # could no longer tell.
    def stale_snapshot?
      return false unless self.class.current_reads_need_locks?

      stale_snapshots = ActiveSupport::IsolatedExecutionState[:wallets_stale_snapshots] ||= Set.new
      key = [self.class.connection.object_id, self.class.table_name, id]
      return true if stale_snapshots.include?(key)

      snapshot = self.class.uncached { self.class.unscoped.where(id: id).pick(:updated_at, :balance) }
      return false if snapshot == [updated_at, read_attribute(:balance)]

      stale_snapshots << key
      transaction = self.class.current_transaction
      transaction.after_commit { stale_snapshots.delete(key) }
      transaction.after_rollback { stale_snapshots.delete(key) }
      true
    end

    # Turns a read a mutation decides on into a current read (see
    # `stale_snapshot?`). Public readers never lock.
    def current_read(relation, lock)
      return relation unless lock && self.class.current_reads_need_locks?

      relation.lock("FOR UPDATE")
    end

    # The same rule for a raw subquery inside a locked statement: MySQL locks
    # (and reads current) rows of a subquery only when the subquery itself
    # says FOR UPDATE.
    def locking_clause(lock)
      return "" unless lock && self.class.current_reads_need_locks?

      " FOR UPDATE"
    end

    # =========================================
    # Credit/Debit Implementation
    # =========================================

    def apply_credit(amount, metadata:, category:, expires_at:, transfer:, extra_attributes: {}, at: evaluation_time)
      mutating_at(at) do
        amount = normalize_positive_amount!(amount)
        validate_expiration!(expires_at, at: evaluation_time)

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

        new_balance = refresh_cached_balance!
        transaction.sync_balance_snapshot!(before: previous_balance, after: new_balance)

        dispatch_callback(:credited,
          wallet: self,
          amount: amount,
          category: category,
          transaction: transaction,
          previous_balance: previous_balance,
          new_balance: new_balance,
          metadata: metadata)

        transaction
      end
    end

    def apply_debit(amount, metadata:, category:, transfer:, extra_attributes: {}, allow_unbacked: allow_negative_balance?, at: evaluation_time)
      mutating_at(at) do
        amount = normalize_positive_amount!(amount)
        previous_balance = balance

        if amount > previous_balance && !allow_unbacked
          reject_insufficient_balance!(amount, previous_balance, metadata)
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

        if remaining_to_allocate.positive? && !allow_unbacked
          raise InsufficientBalance, "Not enough balance buckets to cover the debit"
        end

        new_balance = refresh_cached_balance!
        spend_transaction.sync_balance_snapshot!(before: previous_balance, after: new_balance)

        dispatch_callback(:debited,
          wallet: self,
          amount: amount,
          category: category,
          transaction: spend_transaction,
          previous_balance: previous_balance,
          new_balance: new_balance,
          metadata: metadata)

        dispatch_balance_threshold_callbacks!(previous_balance, new_balance)

        spend_transaction
      end
    end

    def allocate_debit!(spend_transaction, amount)
      remaining_to_allocate = amount

      # Only eligible buckets fund a debit (see `eligible_credits`).
      # Reservations pin no bucket: affordability enforces them, so ordinary
      # debits leave them backed by the longest-lived buckets.
      #
      # Soonest-expiring buckets are consumed first so expirable value never
      # sits unused behind evergreen value; ties (including all-evergreen
      # wallets) fall back to oldest-first.
      #
      # Each bucket's remaining value comes from the same locked statement
      # that loads it, so allocation decides on current rows (see
      # `current_reads_need_locks?`), never on an older snapshot.
      positive_transactions = eligible_credits
        .select(transaction_class.arel_table[Arel.star], Arel.sql("#{remaining_amount_sql} AS allocatable_amount"))
        .order(Arel.sql("COALESCE(expires_at, '9999-12-31 23:59:59'), id ASC"))
        .lock("FOR UPDATE")
        .to_a

      positive_transactions.each do |source_transaction|
        leftover = source_transaction.allocatable_amount.to_i
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
        [{amount: amount, expires_at: nil}]
      when "fixed"
        [{amount: amount, expires_at: expires_at}]
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
          grouped_specs << {amount: allocation.amount, expires_at: expires_at}
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
    #
    # Every term takes the instant to evaluate at and whether to read current
    # rows; both default to the pinned mutation context (see `evaluating_at`),
    # so outside a mutation they read plainly at Time.current.

    # P: the remaining value of unexpired credits, held or not.
    def positive_remaining_balance(at: evaluation_time, lock: current_reads?)
      current_read(transactions.credits.not_expired(at: at), lock)
        .sum(remaining_amount_sql(lock: lock))
        .to_i
    end

    # N: the part of debits no credit backs.
    def unbacked_negative_balance(transaction_scope = transactions.debits, lock: current_reads?)
      connection = transaction_class.connection
      txn_table = connection.quote_table_name(transaction_class.table_name)
      alloc_table = connection.quote_table_name(allocation_class.table_name)
      amount_column = connection.quote_column_name("amount")
      id_column = connection.quote_column_name("id")
      transaction_id_column = connection.quote_column_name("transaction_id")

      current_read(transaction_scope, lock)
        .sum("ABS(#{txn_table}.#{amount_column}) - (SELECT COALESCE(SUM(#{amount_column}), 0) FROM #{alloc_table} WHERE #{transaction_id_column} = #{txn_table}.#{id_column}#{locking_clause(lock)})")
        .to_i
    end

    # C: the remaining value of unexpired credits an active hold covers, each
    # credit counted once however many reasons hold it.
    def covered_remaining_balance(at: evaluation_time, lock: current_reads?)
      return 0 unless holds_enabled?

      current_read(transactions.credits.not_expired(at: at), lock)
        .sum("CASE WHEN #{self.class.coverage_sql(at: at, lock: lock)} THEN #{remaining_amount_sql(lock: lock)} ELSE 0 END")
        .to_i
    end

    # R: the amounts of active reservations.
    def reserved_balance(at: evaluation_time, lock: current_reads?)
      return 0 unless holds_enabled?

      current_read(wallet_holds.reservations.active(at: at), lock).sum(:amount).to_i
    end

    # The buckets a debit may consume at `at`: unexpired, and not covered by
    # an active hold (none at all while a wallet hold is active). The one
    # eligibility definition behind both affordability (through C) and
    # allocation, so the two can never disagree.
    def eligible_credits(at: evaluation_time, lock: current_reads?)
      credits = transactions.credits.not_expired(at: at)
      return credits unless holds_enabled?

      credits.where("NOT #{self.class.coverage_sql(at: at, lock: lock)}")
    end

    # P - C: what FEFO allocation can take from eligible buckets right now.
    def eligible_remaining_balance(at: evaluation_time, lock: current_reads?)
      current_read(eligible_credits(at: at, lock: lock), lock)
        .sum(remaining_amount_sql(lock: lock))
        .to_i
    end

    # A credit's remaining value: its amount minus what debits allocated from
    # it.
    def remaining_amount_sql(lock: current_reads?)
      connection = transaction_class.connection
      txn_table = connection.quote_table_name(transaction_class.table_name)
      alloc_table = connection.quote_table_name(allocation_class.table_name)
      amount_column = connection.quote_column_name("amount")
      id_column = connection.quote_column_name("id")
      source_transaction_id_column = connection.quote_column_name("source_transaction_id")

      "#{txn_table}.#{amount_column} - (SELECT COALESCE(SUM(#{amount_column}), 0) FROM #{alloc_table} WHERE #{source_transaction_id_column} = #{txn_table}.#{id_column}#{locking_clause(lock)})"
    end

    def wallet_holds
      hold_class.where(wallet_id: id)
    end

    # Writes the available balance to the cached column and returns it. Like
    # any cache it can go stale through time alone (expiry, lapsed deadlines),
    # so it is never authoritative for accounting.
    #
    # The row is written even when the balance did not move (a second reason
    # on a held credit, a capture of a whole reservation): every committed
    # change to the ledger must change the wallet row, which is how
    # `stale_snapshot?` knows a snapshot is current (and how PostgreSQL's
    # repeatable read detects a concurrent update on `lock!`).
    def refresh_cached_balance!
      available = current_balance
      write_attribute(:balance, available)
      has_changes_to_save? ? save! : touch
      available
    end

    # =========================================
    # Threshold Callbacks
    # =========================================

    # A refused funding attempt reports once, immediately (its transaction is
    # about to roll back), and names what holds keep out of reach, so the app
    # can say "20 available, 30 held, 50 reserved" rather than just "20".
    def reject_insufficient_balance!(amount, available, metadata)
      held = covered_remaining_balance
      reserved = reserved_balance
      dispatch_insufficient_balance!(amount, available, metadata, held: held, reserved: reserved)

      details = {held: held, reserved: reserved}.reject { |_name, value| value.zero? }.map { |name, value| "#{value} #{name}" }
      raise InsufficientBalance, "Insufficient balance (#{available} < #{amount}#{"; #{details.join(", ")}" if details.any?})"
    end

    # `held:` is the credit value holds cover and `reserved:` the active
    # reservations, so available + held + reserved is the total balance.
    def dispatch_insufficient_balance!(amount, previous_balance, metadata, held: covered_remaining_balance, reserved: reserved_balance)
      dispatch_callback(:insufficient,
        wallet: self,
        amount: amount,
        previous_balance: previous_balance,
        new_balance: previous_balance,
        metadata: metadata.merge(
          available: previous_balance,
          required: amount,
          held: held,
          reserved: reserved
        ))
    end

    def dispatch_balance_threshold_callbacks!(previous_balance, new_balance = balance)
      if !was_low_balance?(previous_balance) && low_balance?(new_balance)
        dispatch_callback(:low_balance,
          wallet: self,
          threshold: config.low_balance_threshold,
          previous_balance: previous_balance,
          new_balance: new_balance)
      end

      # `:balance_depleted` fires when the wallet crosses from a positive
      # balance to ZERO OR LOWER. We use `<= 0` rather than `== 0` because
      # available balance can skip exact zero: an overdraft debit takes it
      # from +100 to -50, and holds or expiry can take it below zero even
      # with `allow_negative_balance` off. Either way the callback is
      # one-shot per crossing — going from -50 to -80 doesn't re-fire
      # because `previous_balance` was already non-positive.
      if previous_balance.positive? && !new_balance.positive?
        dispatch_callback(:depleted,
          wallet: self,
          previous_balance: previous_balance,
          new_balance: new_balance)
      end
    end

    def low_balance?(available = balance)
      threshold = config.low_balance_threshold
      return false if threshold.nil?

      available <= threshold
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

    def validate_expiration!(expires_at, at: Time.current)
      return if expires_at.nil?
      raise ArgumentError, "Expiration date must respond to to_datetime" unless expires_at.respond_to?(:to_datetime)

      expiration = begin
        expires_at.to_datetime
      rescue
        raise ArgumentError, "Expiration date must be a valid date or time"
      end

      raise ArgumentError, "Expiration date must be in the future" if expiration <= at
    end

    def normalize_positive_amount!(amount)
      raise ArgumentError, "Amount is required" if amount.nil?

      amount = Wallets::WholeNumber.parse(amount, name: "Amount")
      raise ArgumentError, "Amount must be positive" unless amount.positive?

      amount
    end

    def normalize_metadata(metadata)
      metadata.respond_to?(:to_h) ? metadata.to_h : {}
    end

    def validate_additional_transaction_attributes!(attributes)
      allowed = self.class.additional_transaction_attribute_names.map(&:to_sym)
      requested = attributes.keys.map(&:to_sym)
      unsupported = (requested - allowed) | (requested & CORE_TRANSACTION_ATTRIBUTE_NAMES)
      return attributes if unsupported.empty?

      raise ArgumentError, "Unsupported transaction attributes: #{unsupported.join(", ")}"
    end

    def lock_wallet_pair!(other_wallet)
      first, second = [self, other_wallet].sort_by(&:id)
      first.lock!
      second.lock! unless first.id == second.id
    end

    def normalize_asset_code!
      self.asset_code = Wallets.normalize_asset_code(asset_code).presence
    end
  end

  # The concrete standalone ledger model (table: wallets_wallets via the
  # default config). Embedders subclass WalletBase instead.
  #
  # It keeps holds. Their associations live here, never on WalletBase, so a
  # ledger that did not opt in never touches a holds table.
  class Wallet < WalletBase
    self.hold_class_name = "Wallets::Hold"

    has_many :holds, class_name: "Wallets::Hold", foreign_key: :wallet_id, inverse_of: :wallet

    # Holds reference this wallet's transactions (the credit a hold covers,
    # the debit a reservation was captured into), so they must be destroyed
    # BEFORE the transaction and transfer dependencies WalletBase declares. A
    # `dependent: :destroy` here would be appended after those inherited
    # callbacks; prepending puts it first. It runs inside destroy's
    # transaction, so a hold that refuses to go aborts the whole destroy.
    before_destroy :destroy_holds, prepend: true

    private

    def destroy_holds
      holds.destroy_all
    end
  end
end
