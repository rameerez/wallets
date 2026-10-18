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

    # The smallest step the wallet row's `updated_at` column can record (the
    # timestamp marker of wallet tables without `ledger_revision`).
    MARKER_STEP = Rational(1, 1_000_000)
    private_constant :MARKER_STEP

    # What `hold` holds when no credit is passed at all. A sentinel rather
    # than nil, so a nil from a lookup that found nothing is an error instead
    # of a freeze on the whole wallet.
    WHOLE_WALLET = Object.new.freeze
    private_constant :WHOLE_WALLET

    # What `debit` and `transfer_to` spend when `from:` is left out: any
    # eligible credit, soonest-expiring first. A sentinel for the same reason
    # as WHOLE_WALLET: a nil from a lookup that found nothing must be an
    # error, never a debit that quietly spends some other credit.
    ELIGIBLE_CREDITS = Object.new.freeze
    private_constant :ELIGIBLE_CREDITS

    # The keywords `credit(..., hold: {...})` accepts: the ones `hold` takes.
    ARRIVAL_HOLD_OPTIONS = %i[category until metadata].freeze
    private_constant :ARRIVAL_HOLD_OPTIONS

    # The columns the ledger itself writes on the wallet row
    # (`refresh_cached_balance!`); the caller never sets them.
    LEDGER_WRITTEN_COLUMNS = %w[balance ledger_revision updated_at].freeze
    private_constant :LEDGER_WRITTEN_COLUMNS

    # Every command starts by locking the wallet row, and Rails refuses to
    # lock a record with unsaved changes. A rolled-back command leaves
    # exactly that behind: the cached balance, the revision and `updated_at`
    # it had written stay in memory, marked as unsaved changes, once its
    # savepoint or the caller's transaction is rolled back, and the next
    # command on the same instance would raise. Those columns are the
    # ledger's, not the caller's, and the lock reads the row again anyway,
    # so they are discarded first. A change to any other attribute is the
    # caller's, and Rails' refusal stands.
    def lock!(lock = true)
      restore_attributes(changed & LEDGER_WRITTEN_COLUMNS) if persisted?
      super
    end

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
      transfer_completed: :transfer_completed,
      hold_created: :hold_created,
      hold_released: :hold_released
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
    #
    # @api private Public only because wallet instances ask it through their
    # class; not part of the supported API, and free to change in any release.
    def self.current_reads_need_locks?
      transaction_class.connection.adapter_name.match?(SNAPSHOT_READ_ADAPTERS)
    end

    # One definition of "held" for credits, shared by `held_balance`, FEFO
    # eligibility and `Transaction#held?`, so the three can never disagree.
    # SQL that is true for a credit row of this ledger that an active hold
    # covers at `at`: a hold on that very credit, or a hold on its whole
    # wallet. Correlated EXISTS, never a join, so a credit held for two
    # reasons still counts once.
    #
    # @api private Public only so `Transaction#held?` and friends share this
    # one definition; not part of the supported API, and free to change in
    # any release.
    def self.coverage_sql(at:, lock: false)
      holds = hold_class.arel_table
      credits = transaction_class.arel_table
      active_holds = hold_class.active(at: at).select(Arel.sql("1"))
      active_holds = active_holds.lock("FOR UPDATE") if lock && current_reads_need_locks?

      credit_holds = active_holds.where(holds[:transaction_id].eq(credits[:id]))
      wallet_holds = active_holds.coverage.wallet_scoped.where(holds[:wallet_id].eq(credits[:wallet_id]))

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
    # the wallet lock instead. The cached column is what is validated, never
    # the `balance` reader (see `read_attribute_for_validation`).
    validates :balance, numericality: {only_integer: true}

    before_validation :normalize_asset_code!

    # A caller's own write to the wallet row inside a transaction leaves that
    # transaction reading its own version of the row, which then matches the
    # locked row even while its ledger snapshot is stale (see
    # `stale_snapshot?`). Such a wallet counts as stale for the rest of the
    # transaction: conservative, and it only ever costs locking reads.
    # Creating the wallet is exempt (nobody else can have touched a ledger
    # nobody else can see), and so is the ledger's own refresh. Writes that
    # skip Active Record callbacks (raw SQL, `update_columns`) are outside the
    # supported API.
    after_save :remember_own_write, if: :saved_changes?, unless: :previously_new_record?
    after_touch :remember_own_write

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

    # A ledger without holds computes exactly what 0.3 did, through the two
    # helpers an embedder may override (D12). With holds, every term comes
    # from one statement (see `balance_components`).
    def current_balance
      return positive_remaining_balance - unbacked_negative_balance unless holds_enabled?

      balance_components.available
    end

    def available_balance
      balance
    end

    # Validations read the cached `balance` column. The `balance` reader
    # computes the available balance from the whole ledger, so validating it
    # would run that statement on every save (several times per command) and
    # make even `create!` read the holds table.
    def read_attribute_for_validation(attribute)
      (attribute.to_s == "balance") ? read_attribute(:balance) : super
    end

    # Value in the ledger that holds keep out of `balance`: held credits plus
    # active reservations. It can exceed `total_balance` (a hold over value
    # that is already reserved, or reservations whose backing expired), and is
    # deliberately not capped.
    def held_balance
      return 0 unless holds_enabled?

      balance_components.held
    end

    # Everything the ledger holds for the owner, spendable or not: P - N.
    # Without holds it is simply `balance`, whatever policy an embedder's
    # `current_balance` applies.
    def total_balance
      return balance unless holds_enabled?

      balance_components.total
    end

    # Whether a hold covers the whole wallet, including credits received
    # later. A pending reservation is not a blanket hold.
    def on_hold?
      return false unless holds_enabled?

      wallet_holds.coverage.wallet_scoped.active(at: evaluation_time).exists?
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

    # Adds value to the wallet. With `hold:` or `available_at:` the value
    # arrives held: the credit and its hold are written in one step, so it is
    # never spendable in between, and the callbacks report the finished
    # operation.
    #
    #   wallet.credit(751, category: :reward, hold: :pending_validation)
    #   wallet.credit(751, category: :reward, hold: {category: :pending_validation, until: 3.months.from_now, metadata: {ride_id: 7}})
    #   wallet.credit(500, category: :reward, available_at: 14.days.from_now) # held as :pending until then
    def credit(amount, metadata: {}, category: :credit, expires_at: nil, transfer: nil, hold: nil, available_at: nil, **extra_transaction_attributes)
      metadata = normalize_metadata(metadata)
      extra_transaction_attributes = validate_additional_transaction_attributes!(extra_transaction_attributes)
      arrival_hold = arrival_hold_attributes(hold, available_at)

      # A savepoint even inside a caller's transaction, like every command: a
      # credit that cannot get its hold must not survive as a spendable credit
      # because the caller rescued the error and committed.
      with_lock(requires_new: true) do
        mutating_at(Time.current) do
          # Value that becomes available at an instant already reached is
          # simply available: there is nothing left to hold.
          arrival_hold = nil if available_at && arrival_hold[:releases_at] <= evaluation_time

          apply_credit(
            amount,
            metadata: metadata,
            category: category,
            expires_at: expires_at,
            transfer: transfer,
            extra_attributes: extra_transaction_attributes,
            hold: arrival_hold
          )
        end
      end
    end

    # Takes value out of the wallet. Ordinarily it spends eligible credits,
    # soonest-expiring first, and never touches held value.
    #
    # `from:` names the credits to take it from instead, in the order given.
    # It is the one way to take value a hold covers, so it is how a hold ends
    # the other way: releasing gives the value back, `from:` takes it away.
    # The debit is allocated to the named credits in full or not at all,
    # never to other credits and never to debt, and the holds stay exactly as
    # they were: a cancelled credit keeps its reasons with nothing left to
    # hold.
    #
    #   wallet.debit(751, category: :reversal, from: credit, metadata: {reason: "reward_rejected"})
    #   wallet.debit(150, category: :reversal, from: [first_credit, second_credit])
    #
    # Held value needs no funding, but the rest of a targeted debit does:
    # with overdrafts off, what it takes from unheld credits must fit in the
    # available balance, so naming an unheld credit cannot spend value that a
    # reservation set aside, nor deepen a deficit.
    def debit(amount, metadata: {}, category: :debit, transfer: nil, from: ELIGIBLE_CREDITS, **extra_transaction_attributes)
      metadata = normalize_metadata(metadata)
      extra_transaction_attributes = validate_additional_transaction_attributes!(extra_transaction_attributes)
      sources = named_credits(from)

      with_lock(requires_new: true) do
        apply_debit(
          amount,
          metadata: metadata,
          category: category,
          transfer: transfer,
          extra_attributes: extra_transaction_attributes,
          from: sources
        )
      end
    end

    # =========================================
    # Holds & Reservations
    # =========================================

    # Keeps value in the wallet but out of `balance` until the hold is
    # released or its deadline passes. Given a credit, it holds that credit's
    # whole remaining value; without one, it holds every credit in the wallet,
    # including credits that arrive later. Holding an already held credit is
    # fine: each hold is an independent reason, released on its own.
    #
    #   wallet.hold(credit, category: :fraud_review, metadata: {case_id: 42})
    #   wallet.hold(category: :chargeback, until: 30.days.from_now)
    #
    # Only leaving the credit out holds the whole wallet: an explicit nil
    # (a credit that was looked up and not found) is refused.
    def hold(credit = WHOLE_WALLET, category:, until: nil, metadata: {})
      ensure_holds_enabled!
      raise ArgumentError, "Pass no credit to hold the whole wallet; nil is not a credit" if credit.nil?

      credit = nil if credit.equal?(WHOLE_WALLET)
      metadata = normalize_metadata(metadata)
      # `until` is a Ruby keyword: the argument reads as plain English at the
      # call site, and the binding is the only way to reach it in here.
      releases_at = normalize_deadline(binding.local_variable_get(:until))

      with_lock(requires_new: true) do
        mutating_at(Time.current) do
          # The target first: a wrong argument is a wrong argument, whatever
          # the deadline says.
          ensure_holdable!(credit) unless credit.nil?
          ensure_deadline_ahead!(releases_at)

          place_hold!(credit: credit, category: category, releases_at: releases_at, metadata: metadata)
        end
      end
    end

    # Sets an amount of the available balance aside, like a pending card
    # charge; reservations add up. Funded exactly like a debit: the amount
    # must fit in `balance` unless `allow_negative_balance` is on.
    #
    #   wallet.reserve(3_000, category: :booking, until: 7.days.from_now, metadata: {booking_id: 9})
    def reserve(amount, category:, until: nil, metadata: {})
      ensure_holds_enabled!
      amount = normalize_positive_amount!(amount)
      metadata = normalize_metadata(metadata)
      releases_at = normalize_deadline(binding.local_variable_get(:until))

      with_lock(requires_new: true) do
        mutating_at(Time.current) do
          ensure_deadline_ahead!(releases_at)
          available = balance

          if amount > available && !allow_negative_balance?
            reject_insufficient_balance!(amount, available, metadata)
          end

          place_hold!(amount: amount, category: category, releases_at: releases_at, metadata: metadata, previous_balance: available)
        end
      end
    end

    # =========================================
    # Transfers
    # =========================================

    # Moves value to another wallet of the same asset. `from:` works as it
    # does on `debit`: the outbound leg is taken from the named credits only,
    # held value included, and the inbound legs are credited as usual.
    #
    #   wallet.transfer_to(platform.wallet, 751, category: :reversal, from: credit)
    def transfer_to(other_wallet, amount, category: :transfer, metadata: {}, expiration_policy: nil, expires_at: nil, from: ELIGIBLE_CREDITS)
      raise InvalidTransfer, "Target wallet is required" if other_wallet.nil?
      raise InvalidTransfer, "Source wallet must be persisted" unless persisted?
      raise InvalidTransfer, "Target wallet must be persisted" unless other_wallet.persisted?
      # The class first: two ledgers keep separate tables, so a wallet of
      # another class can share this wallet's id without being this wallet.
      raise InvalidTransfer, "Wallet classes must match" unless other_wallet.instance_of?(self.class)
      raise InvalidTransfer, "Cannot transfer to the same wallet" if other_wallet.id == id
      raise InvalidTransfer, "Wallet assets must match" unless asset_code == other_wallet.asset_code

      amount = normalize_positive_amount!(amount)
      metadata = normalize_metadata(metadata)
      resolved_policy, inbound_expires_at = resolve_transfer_expiration!(expiration_policy, expires_at)
      sources = named_credits(from)

      # A savepoint even inside a caller's transaction, like every command: a
      # transfer whose inbound leg fails must take its outbound debit and its
      # Transfer row with it, even when the caller rescues and commits.
      self.class.transaction(requires_new: true) do
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
          #
          # A targeted transfer is funded like a targeted debit instead (see
          # `named_buckets!`), and checked here for the same reason: a refusal
          # must leave no Transfer row behind.
          if sources
            named_buckets!(sources, amount, previous_balance, metadata)
          elsif amount > previous_balance && !allow_negative_balance?
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
          # A targeted transfer never has an unbacked portion (the named
          # credits fund all of it or the transfer is refused above), so it
          # always keeps its sources' expirations, even when they are held
          # and nothing is available.
          #
          # Callers who care about a specific expiration on the inbound side
          # should pass `expiration_policy: :fixed, expires_at: …`. Those are
          # honored unchanged because they don't depend on source-bucket
          # walking. Same for an explicit `:none`.
          if resolved_policy == "preserve" && sources.nil? && amount > eligible_remaining_balance
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

          _outbound_transaction, allocations = apply_debit_with_allocations(
            amount,
            category: :transfer_out,
            metadata: shared_metadata.merge(
              "counterparty_wallet_id" => other_wallet.id,
              "counterparty_owner_id" => other_wallet.owner_id,
              "counterparty_owner_type" => other_wallet.owner_type
            ),
            transfer: transfer,
            from: sources
          )

          build_transfer_inbound_credit_specs(
            transfer: transfer,
            allocations: allocations,
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

      # Successful ledger callbacks describe committed facts, so they wait for
      # the commit. They are queued on the innermost open transaction, the
      # command's own savepoint: a failure later in the command rolls it back
      # and drops them, even when the caller rescues and commits; a released
      # savepoint hands them to its parent; an enclosing rollback drops them.
      # The same rules as Active Record's own after_commit, which also treats a
      # `transaction(joinable: false)` as a commit boundary. Failure callbacks
      # are intentionally immediate because their transaction is about to roll
      # back by design.
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
    # command increments the wallet's `ledger_revision` under its lock
    # (`refresh_cached_balance!`), so when the revision this transaction's
    # snapshot shows is the revision the lock returned, nothing was committed
    # to this wallet's ledger after the snapshot and plain reads already see
    # it as it is now. That covers every command that runs first in its
    # transaction, or in a transaction that created the wallet, or that read
    # before taking the lock without anyone writing in between. A counter,
    # not a timestamp: no clock, `no_touching` or `touch(time:)` can make two
    # revisions of the ledger look alike.
    #
    # Locking reads everywhere would be correct but not safe to run: InnoDB
    # takes gap locks on the ranges they scan, and the gaps after a wallet's
    # newest rows are the very gaps OTHER wallets insert into, so unrelated
    # concurrent debits or sign-ups deadlock each other (a tenth of them in a
    # stress run). Kept to the stale case, which needs a caller that read
    # first AND a concurrent change to this same wallet, they are rare.
    #
    # A stale verdict is remembered for as long as the real database
    # transaction lasts, savepoints and all: once this transaction writes the
    # wallet row, its snapshot shows its own write and could no longer tell.
    def stale_snapshot?
      return false unless self.class.current_reads_need_locks?
      return true if remembered_stale_snapshots.key?(stale_snapshot_key)

      columns = row_marker_columns
      snapshot = self.class.uncached { self.class.unscoped.where(id: id).pick(*columns) }
      return false if Array.wrap(snapshot) == columns.map { |column| read_attribute(column) }

      remember_stale_snapshot!
      true
    end

    # What tells one committed state of this wallet's ledger from another:
    # its `ledger_revision`. See `ledger_revision?` for tables without one.
    def row_marker_columns
      ledger_revision? ? %w[ledger_revision] : %w[updated_at balance]
    end

    # Whether the wallet table has `ledger_revision`, as every 0.4 schema
    # does. The counter is the robust marker. A ledger without holds on an
    # embedder's 0.3-era table falls back to a strictly increasing
    # `updated_at` (see `next_row_marker`) compared together with `balance`:
    # it keeps those schemas working, but another connection's
    # `touch(time:)` can still spoof it, so embedders should add the column
    # (bigint, not null, default 0). A ledger that keeps holds refuses to run
    # without it, like a ledger whose holds table is missing: a spoofed
    # marker could let a stale read spend held value.
    def ledger_revision?
      return true if has_attribute?(:ledger_revision)
      return false unless holds_enabled?

      raise Error, "#{self.class.name} keeps holds, so its wallet table needs a ledger_revision column (bigint, not null, default 0)"
    end

    # Remembers the verdict with the real transaction it belongs to. The
    # hook at that transaction's end is only the cleanup: Active Record skips
    # the remaining commit hooks when an earlier one raises (a host model's
    # `after_commit`, say), and a verdict outliving its transaction would make
    # every later one on this connection lock for nothing. So a verdict whose
    # transaction has ended counts as gone, whether or not its hook ran.
    def remember_stale_snapshot!
      remembered = remembered_stale_snapshots
      key = stale_snapshot_key
      return if remembered.key?(key)

      connection = self.class.connection
      remembered[key] = real_transaction(connection)
      at_end_of_real_transaction(connection) { remembered.delete(key) }
    end

    # Per thread, and per connection inside it: a verdict is about one
    # connection's database transaction, never another's. Each maps to the
    # real transaction it was reached in, and one whose transaction has ended
    # is dropped on the way out.
    def remembered_stale_snapshots
      remembered = ActiveSupport::IsolatedExecutionState[:wallets_stale_snapshots] ||= {}
      remembered.delete_if { |_key, transaction| transaction&.state&.finalized? }
    end

    # The outermost transaction open on `connection`: the real database
    # transaction, whose snapshot a verdict is about. Active Record keeps no
    # public pointer from a savepoint to its parent, so this reads the
    # transaction manager's stack, an internal structure (the same on Rails
    # 7.2 and 8.1). Its state is public: `finalized?` once it commits or
    # rolls back, on both versions (7.2's `open?` stays true to the end, so
    # it cannot tell). Should a later Rails change the stack, this answers
    # nil, and the verdict then lasts until its hook ends it, exactly as long
    # as it used to: never shorter, which would read a stale snapshot. The
    # current transaction is no substitute, as it may be a savepoint that
    # ends long before the real transaction does.
    def real_transaction(connection)
      manager = connection.transaction_manager
      return unless manager.instance_variable_defined?(:@stack)

      manager.instance_variable_get(:@stack).first
    end

    def stale_snapshot_key
      [self.class.connection.object_id, self.class.table_name, id]
    end

    # Runs the block once the real database transaction open on `connection`
    # ends, by commit or by rollback, however deep in savepoints this is
    # called. A savepoint's own hooks are not enough: one released under a
    # `transaction(joinable: false)` runs its commit hooks at once, with the
    # real transaction (and its snapshot) still open. So each hook hands the
    # block on to the next transaction out, until none is left.
    #
    # The hooks go on Active Record's internal transaction, not on the public
    # `ActiveRecord::Transaction` it exposes: a `transaction(joinable: false)`
    # exposes the null transaction, whose `after_commit` runs at once, and
    # would end a verdict while its transaction still runs.
    def at_end_of_real_transaction(connection, &block)
      transaction = connection.current_transaction
      return yield unless transaction.open?

      hand_on = -> { at_end_of_real_transaction(connection, &block) }
      transaction.after_commit(&hand_on)
      transaction.after_rollback(&hand_on)
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

    # `hold:` (category, releases_at, metadata) places a hold on the new
    # credit before anything reads the balance again, so no snapshot, cache
    # or callback ever sees the value spendable. A credit never lowers the
    # available balance (a hold on arrival covers only the credit itself), so
    # it can cross no threshold.
    def apply_credit(amount, metadata:, category:, expires_at:, transfer:, extra_attributes: {}, hold: nil, at: evaluation_time)
      mutating_at(at) do
        amount = normalize_positive_amount!(amount)
        validate_expiration!(expires_at, at: evaluation_time)
        ensure_deadline_ahead!(hold[:releases_at]) if hold

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
        arrival_hold = hold_class.create!(wallet: self, credit: transaction, **hold) if hold

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
        dispatch_hold_created!(arrival_hold, previous_balance: previous_balance, new_balance: new_balance) if arrival_hold

        transaction
      end
    end

    def apply_debit(...)
      apply_debit_with_allocations(...).first
    end

    # The debit, and the allocations that fund it, each holding the very
    # source row the allocator locked (a transfer keeps their expirations).
    # `from:` is the credits a targeted debit names (see `named_credits`).
    def apply_debit_with_allocations(amount, metadata:, category:, transfer:, extra_attributes: {}, allow_unbacked: allow_negative_balance?, from: nil, at: evaluation_time)
      mutating_at(at) do
        amount = normalize_positive_amount!(amount)
        previous_balance = balance

        buckets = named_buckets!(from, amount, previous_balance, metadata) if from
        if from.nil? && amount > previous_balance && !allow_unbacked
          reject_insufficient_balance!(amount, previous_balance, metadata)
        end

        # A targeted debit is never left unbacked, whatever the flag says.
        spend_transaction, allocations = post_debit!(
          amount,
          metadata: metadata,
          category: category,
          transfer: transfer,
          extra_attributes: extra_attributes,
          buckets: buckets,
          allow_unbacked: allow_unbacked && from.nil?
        )

        new_balance = refresh_cached_balance!
        report_debit!(spend_transaction, amount: amount, category: category, metadata: metadata, previous_balance: previous_balance, new_balance: new_balance)
        dispatch_balance_threshold_callbacks!(previous_balance, new_balance)

        [spend_transaction, allocations]
      end
    end

    # Writes a debit and the allocations that fund it: from `buckets` when
    # given, else from eligible credits. Whatever no bucket backs is left
    # unbacked, which only `allow_unbacked` permits. Funding has been checked
    # by then; this only refuses to write a debit that does not add up.
    def post_debit!(amount, metadata:, category:, transfer:, extra_attributes: {}, buckets: nil, allow_unbacked: false)
      spend_transaction = transactions.create!(
        {
          amount: -amount,
          category: category,
          metadata: metadata,
          transfer: transfer
        }.merge(extra_attributes)
      )

      allocations = allocate_debit!(spend_transaction, amount, buckets: buckets)
      remaining_to_allocate = amount - allocations.sum(&:amount)

      if remaining_to_allocate.positive? && !allow_unbacked
        raise InsufficientBalance, "Not enough balance buckets to cover the debit"
      end

      [spend_transaction, allocations]
    end

    # The debit's balance snapshot and its `debited` callback, from the
    # balances before and after the whole command.
    def report_debit!(spend_transaction, amount:, category:, metadata:, previous_balance:, new_balance:)
      spend_transaction.sync_balance_snapshot!(before: previous_balance, after: new_balance)

      dispatch_callback(:debited,
        wallet: self,
        amount: amount,
        category: category,
        transaction: spend_transaction,
        previous_balance: previous_balance,
        new_balance: new_balance,
        metadata: metadata)
    end

    # Allocates `amount` of the debit to buckets and returns the allocations,
    # in order: the named `buckets` of a targeted debit, else every eligible
    # credit (see `eligible_buckets`). Whatever no bucket can back is left
    # unbacked.
    def allocate_debit!(spend_transaction, amount, buckets: nil)
      split_across(buckets || eligible_buckets, amount).map do |source_transaction, portion|
        allocation_class.create!(
          spend_transaction: spend_transaction,
          source_transaction: source_transaction,
          amount: portion
        )
      end
    end

    # The buckets an ordinary debit walks, locked, in the order it spends
    # them.
    #
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
    def eligible_buckets
      eligible_credits
        .select(transaction_class.arel_table[Arel.star], Arel.sql("#{remaining_amount_sql} AS allocatable_amount"))
        .order(Arel.sql("COALESCE(expires_at, '9999-12-31 23:59:59'), id ASC"))
        .lock("FOR UPDATE")
        .to_a
    end

    # Splits `amount` across `buckets` in their order: each gives what it has
    # left until nothing is left to take. Returns [bucket, portion] pairs;
    # their sum falls short of `amount` only when the buckets run out.
    def split_across(buckets, amount)
      remaining_to_allocate = amount

      buckets.each_with_object([]) do |bucket, portions|
        break portions unless remaining_to_allocate.positive?

        portion = [bucket.allocatable_amount.to_i, remaining_to_allocate].min
        next unless portion.positive?

        portions << [bucket, portion]
        remaining_to_allocate -= portion
      end
    end

    # =========================================
    # Targeted Debit Implementation (`from:`)
    # =========================================

    # The credits `from:` names, as far as they can be checked without the
    # ledger: one saved credit of this ledger, or a list of distinct ones, in
    # the caller's order. nil when `from:` was left out. Whose they are,
    # whether they are credits, and what they have left to give is read under
    # the wallet lock (see `named_buckets!`), never taken from the caller's
    # copies.
    def named_credits(from)
      return if from.equal?(ELIGIBLE_CREDITS)

      ensure_holds_enabled!
      raise ArgumentError, "from: is nil; leave it out to spend any eligible credit" if from.nil?

      credits = Array.wrap(from)
      raise ArgumentError, "from: names no credit" if credits.empty?

      credits.each do |credit|
        unless credit.instance_of?(transaction_class)
          raise ArgumentError, "from: takes #{transaction_class.name} credits, not #{credit.class.name}"
        end
        raise ArgumentError, "from: takes saved credits only" unless credit.persisted?
      end

      repeated = credits.map(&:id).tally.select { |_id, count| count > 1 }.keys
      raise ArgumentError, "from: names transaction #{repeated.join(", ")} more than once" if repeated.any?

      credits
    end

    # The named credits, read again under the wallet lock in the caller's
    # order, once they are known to fund `amount` (D7, D8). Returns them as
    # the buckets to allocate from; raises otherwise, before anything is
    # written.
    #
    # - Every one is a credit of this wallet; anything else is a wrong
    #   argument (ArgumentError), like `hold` draws it.
    # - A credit expired at this instant has nothing left to give, exactly
    #   like a spent one, so it is passed over and never allocated from:
    #   handing on its value would create value that no longer exists,
    #   whatever a transfer's expiration policy.
    # - Together the rest hold at least `amount`: a targeted debit is
    #   allocated to them in full, never to other credits and never to debt.
    # - With overdrafts off, the part they give from unheld value must fit in
    #   the available balance, floored at zero. Held value is not part of
    #   the available balance, so taking it needs no funding; unheld value
    #   is, so naming an unheld credit can neither spend what a reservation
    #   set aside nor deepen a deficit.
    def named_buckets!(credits, amount, available, metadata)
      buckets = locked_named_buckets(credits)
      portions = split_across(buckets, amount)
      found = portions.sum { |_bucket, portion| portion }
      covered_consumed = portions.sum { |bucket, portion| covered_bucket?(bucket) ? portion : 0 }

      if found < amount
        reject_insufficient_balance!(amount, available, metadata,
          comparison: "#{found} < #{amount} in the named credits",
          covered_consumed: covered_consumed)
      end

      needed = amount - covered_consumed
      if needed > [available, 0].max && !allow_negative_balance?
        reject_insufficient_balance!(amount, available, metadata,
          comparison: covered_consumed.zero? ? "#{available} < #{amount}" : "#{available} < #{amount} - #{covered_consumed} from held credits",
          covered_consumed: covered_consumed)
      end

      buckets
    end

    # One locked statement, like the buckets an ordinary debit walks: each
    # named credit with its remaining value and whether an active hold covers
    # it, all at this instant and as the rows are now. The expired ones are
    # left out: their remaining value is what they held, not what they can
    # still give.
    def locked_named_buckets(credits)
      at = evaluation_time
      rows = transactions.where(id: credits.map(&:id))
        .select(
          transaction_class.arel_table[Arel.star],
          Arel.sql("#{remaining_amount_sql} AS allocatable_amount"),
          Arel.sql("CASE WHEN #{self.class.coverage_sql(at: at, lock: current_reads?)} THEN 1 ELSE 0 END AS covered_bucket")
        )
        .lock("FOR UPDATE")
        .index_by(&:id)

      credits.filter_map do |credit|
        row = rows[credit.id] || raise(ArgumentError, missing_credit_message(credit))
        raise ArgumentError, "Transaction #{credit.id} is a debit: only credits can fund a targeted debit" unless row.credit?

        row unless row.expired?(at: at)
      end
    end

    # Read from the flag `locked_named_buckets` selects with each row.
    def covered_bucket?(bucket)
      bucket.read_attribute(:covered_bucket).to_i == 1
    end

    def missing_credit_message(credit)
      if transaction_class.where(id: credit.id).exists?
        "Transaction #{credit.id} belongs to another wallet"
      else
        "Transaction #{credit.id} no longer exists"
      end
    end

    # =========================================
    # Hold Implementation
    # =========================================

    # Writes a hold and reports it: one cache refresh, `hold_created`, then
    # the threshold crossings from the balances before and after. A hold can
    # lower the available balance (a credit hold, a wallet hold, a
    # reservation) or leave it where it was (another reason on value already
    # held), and only a real crossing is reported.
    def place_hold!(previous_balance: balance, **attributes)
      hold = hold_class.create!(wallet: self, **attributes)
      new_balance = refresh_cached_balance!

      dispatch_hold_created!(hold, previous_balance: previous_balance, new_balance: new_balance)
      dispatch_balance_threshold_callbacks!(previous_balance, new_balance)

      hold
    end

    # The wallet side of `Hold#release!`. The wallet is locked first, like in
    # every command, and only then is the hold read, so concurrent releases
    # (or a release racing a capture) queue on the wallet and every one after
    # the first finds the hold already ended. Releasing gives value back and
    # can never cross a low-balance threshold, so none is evaluated.
    def release_hold!(hold, reason:, metadata:)
      metadata = normalize_metadata(metadata)

      ending_hold(hold) do
        mutating_at(Time.current) do
          # A locking read: the hold as it is now, whatever an earlier read in
          # this transaction saw.
          hold.lock!

          if hold.active?(at: evaluation_time)
            previous_balance = balance
            hold.update!(released_at: evaluation_time, release_reason: reason, release_metadata: metadata)
            new_balance = refresh_cached_balance!

            dispatch_hold_released!(hold, previous_balance: previous_balance, new_balance: new_balance)
          end

          hold
        end
      end
    end

    # Runs a command that ends `hold`, a release or a capture, under the
    # wallet lock and in its own savepoint. Should it fail, the caller's copy
    # of the hold is read back from the ledger: Active Record leaves a record
    # holding the values a rolled-back write gave it, so the copy would
    # otherwise go on reading released (or captured, linked to a debit that
    # never existed), and a retry that checks `active?` or `captured?` first
    # would never run. If even that read fails, the original error is the
    # one worth raising.
    #
    # It is a current read, locking where plain reads may answer from an
    # older snapshot (MySQL, see `current_reads_need_locks?`). A plain one
    # there would undo what the command's own locking read had just shown:
    # a capture refused because another connection captured first would
    # leave the copy reading uncaptured again. It locks the hold's row by
    # its primary key, no range, until the caller's transaction ends.
    def ending_hold(hold, &block)
      with_lock(requires_new: true, &block)
    rescue => error
      begin
        hold.reload(lock: self.class.current_reads_need_locks?)
      rescue ActiveRecord::ActiveRecordError
        nil
      end
      raise error
    end

    # The wallet side of `Hold#capture!`: one composite step (D9). The wallet
    # is locked first and the reservation read as it is now, exactly like a
    # release, so a capture racing a release or another capture finds the
    # reservation already ended and creates nothing.
    #
    # The reservation becomes the debit: the amount it set aside funds its
    # own capture, while every other reservation stays fully in force. The
    # debit spends eligible credits only, like any ordinary debit, so value
    # a hold covers is never captured. The balances the debit's snapshot and
    # the callbacks report are the ones before and after the whole step,
    # never the instant in between where the reservation is gone and the
    # debit not yet posted: capturing a fully reserved wallet reads 0 -> 0.
    def capture_reservation!(reservation, amount, category:, metadata:)
      metadata = normalize_metadata(metadata)

      ending_hold(reservation) do
        mutating_at(Time.current) do
          # A locking read: the reservation as it is now, whatever an earlier
          # read in this transaction saw.
          reservation.lock!
          ensure_capturable!(reservation)
          amount = capture_amount(reservation, amount)

          previous_balance = balance
          available_for_capture = previous_balance + reservation.amount

          if amount > available_for_capture && !allow_negative_balance?
            reject_insufficient_balance!(amount, previous_balance, metadata,
              comparison: "#{available_for_capture} < #{amount} to capture reservation #{reservation.id}",
              available_for_capture: available_for_capture)
          end

          # With overdrafts on, a capture beyond the eligible credits leaves
          # exactly the rest unbacked; one within them leaves no debt at all,
          # however underfunded the other reservations end up.
          debit, _allocations = post_debit!(amount, metadata: metadata, category: category, transfer: nil, allow_unbacked: allow_negative_balance?)
          reservation.update!(released_at: evaluation_time, release_reason: "captured", capture_transaction: debit)
          new_balance = refresh_cached_balance!

          report_debit!(debit, amount: amount, category: category, metadata: metadata, previous_balance: previous_balance, new_balance: new_balance)
          dispatch_hold_released!(reservation, previous_balance: previous_balance, new_balance: new_balance, transaction: debit)
          dispatch_balance_threshold_callbacks!(previous_balance, new_balance)

          debit
        end
      end
    end

    # What a capture takes: the reserved amount unless told otherwise, and
    # never more. A positive whole number, parsed like any debit's. Read only
    # once the reservation is known to be capturable, so that retrying a
    # finished capture raises Wallets::InvalidHold whatever amount it
    # repeats, never an ArgumentError about the amount.
    def capture_amount(reservation, amount)
      return reservation.amount if amount.nil?

      amount = normalize_positive_amount!(amount)
      if amount > reservation.amount
        raise ArgumentError, "Cannot capture #{amount}: reservation #{reservation.id} sets aside #{reservation.amount}"
      end

      amount
    end

    # Only an active reservation can be captured, and only once. Read at the
    # command's instant: a reservation is gone from its deadline on.
    def ensure_capturable!(reservation)
      unless reservation.reservation?
        raise InvalidHold, "Hold #{reservation.id} holds credit value: only a reservation can be captured"
      end
      if reservation.captured?
        raise InvalidHold, "Reservation #{reservation.id} was already captured (transaction #{reservation.capture_transaction_id})"
      end
      if reservation.released?
        raise InvalidHold, "Reservation #{reservation.id} was released and can no longer be captured"
      end
      unless reservation.active?(at: evaluation_time)
        raise InvalidHold, "Reservation #{reservation.id} lapsed at #{reservation.releases_at.iso8601} and can no longer be captured"
      end
    end

    # A credit can be held when it is a saved credit of this very wallet and
    # ledger, still unexpired at the command's instant, with value left to
    # hold. Read from the database under the wallet lock, never from the
    # caller's copy, so a debit that just spent it is seen.
    #
    # The same line as `from:` draws: anything that is not a credit of this
    # wallet is a wrong argument (ArgumentError); a credit of this wallet
    # that the ledger's state rules out, expired or spent at this instant,
    # is a hold that cannot be placed now (InvalidHold).
    def ensure_holdable!(credit)
      unless credit.instance_of?(transaction_class)
        raise ArgumentError, "A hold covers a #{transaction_class.name}, not #{credit.class.name}"
      end
      raise ArgumentError, "Only a saved credit can be held" unless credit.persisted?

      row = current_read(transaction_class.where(id: credit.id), current_reads?)
        .pick(:wallet_id, :amount, :expires_at, Arel.sql(remaining_amount_sql))
      raise ArgumentError, "Transaction #{credit.id} no longer exists" if row.nil?

      wallet_id, amount, expires_at, remaining = row
      raise ArgumentError, "Transaction #{credit.id} belongs to another wallet" unless wallet_id == id
      raise ArgumentError, "Transaction #{credit.id} is a debit: only credits can be held" unless amount.positive?
      raise InvalidHold, "Credit #{credit.id} has expired" if expires_at.present? && expires_at <= evaluation_time
      raise InvalidHold, "Credit #{credit.id} has no remaining value to hold" unless remaining.to_i.positive?
    end

    # The hold a credit arrives under, from `hold:` or `available_at:`,
    # checked before anything is written. `hold:` is a category, or a Hash
    # with the same keywords `hold` takes.
    def arrival_hold_attributes(hold, available_at)
      return if hold.nil? && available_at.nil?
      raise ArgumentError, "Pass hold: or available_at:, not both" unless hold.nil? || available_at.nil?

      ensure_holds_enabled!
      return {category: :pending, releases_at: normalize_deadline(available_at, name: "available_at:"), metadata: {}} unless available_at.nil?

      options =
        case hold
        when Symbol, String then {category: hold}
        when Hash then hold.symbolize_keys
        else raise ArgumentError, "hold: takes a category or a Hash of category:, until: and metadata:, not #{hold.inspect}"
        end

      unknown = options.keys - ARRIVAL_HOLD_OPTIONS
      raise ArgumentError, "Unknown hold: options: #{unknown.join(", ")}" if unknown.any?
      raise ArgumentError, "hold: needs a category" unless options.key?(:category)

      {
        category: options[:category],
        releases_at: normalize_deadline(options[:until]),
        metadata: normalize_metadata(options.fetch(:metadata, {}))
      }
    end

    # The instant a deadline names, read the way Active Record reads it into
    # a datetime column (strings and dates in Time.zone), so the instant a
    # command checks is the instant it stores. Anything that is not a time is
    # refused: stored, it would quietly mean "no deadline".
    def normalize_deadline(value, name: "until:")
      return if value.nil?

      deadline = begin
        value.in_time_zone if value.respond_to?(:in_time_zone)
      rescue ArgumentError
        nil
      end

      deadline || raise(ArgumentError, "#{name} must be a time, not #{value.inspect}")
    end

    # A deadline already reached would make a hold that is over before it
    # starts: a caller error to surface, never a row to store.
    def ensure_deadline_ahead!(releases_at)
      return if releases_at.nil? || releases_at > evaluation_time

      raise InvalidHold, "A hold's deadline must be in the future (until: #{releases_at.iso8601})"
    end

    # A ledger that did not opt in refuses every hold command here, before a
    # single query runs.
    def ensure_holds_enabled!
      self.class.hold_class
    end

    def dispatch_hold_created!(hold, previous_balance:, new_balance:)
      dispatch_callback(:hold_created,
        wallet: self,
        hold: hold,
        amount: hold.amount,
        category: hold.category,
        previous_balance: previous_balance,
        new_balance: new_balance,
        metadata: hold.metadata)
    end

    # The same shape as `hold_created`, with the release metadata, and the
    # debit a capture posted as the `transaction`.
    def dispatch_hold_released!(hold, previous_balance:, new_balance:, transaction: nil)
      dispatch_callback(:hold_released,
        wallet: self,
        hold: hold,
        amount: hold.amount,
        category: hold.category,
        transaction: transaction,
        previous_balance: previous_balance,
        new_balance: new_balance,
        metadata: hold.release_metadata)
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

    def build_transfer_inbound_credit_specs(transfer:, allocations:, amount:, expiration_policy:, expires_at:)
      case expiration_policy
      when "none"
        [{amount: amount, expires_at: nil}]
      when "fixed"
        [{amount: amount, expires_at: expires_at}]
      when "preserve"
        build_preserved_transfer_inbound_credit_specs(transfer, allocations, amount)
      else
        raise ArgumentError, "Unsupported transfer expiration policy: #{expiration_policy}"
      end
    end

    # Built from the allocations as the allocator made them, each holding the
    # source row it locked. Never re-read: a plain read could answer from a
    # stale snapshot that has never seen a bucket committed after it.
    def build_preserved_transfer_inbound_credit_specs(transfer, allocations, amount)
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
    # Every term reads the pinned mutation context (see `evaluating_at`): the
    # instant to evaluate at and whether to read current rows. Outside a
    # mutation that is Time.current and plain reads.

    # The terms of the balance at one instant: P (the remaining value of
    # unexpired credits), C (the part of P an active hold covers), R (active
    # reservations) and N (the debt no credit backs).
    BalanceComponents = Struct.new(:positive, :covered, :reserved, :unbacked) do
      def available
        positive - covered - reserved - unbacked
      end

      def held
        covered + reserved
      end

      def total
        positive - unbacked
      end
    end
    private_constant :BalanceComponents

    # All four terms from ONE statement over this wallet's transactions, with
    # R as a scalar subquery in the same statement. Separate statements would
    # each see their own snapshot under read committed (PostgreSQL's
    # default): a credit committed between two of them could count in P yet
    # miss C. One statement is one snapshot, so available, held and total
    # always agree. Ledgers that keep holds only: the others never query one.
    def balance_components
      at = evaluation_time
      lock = current_reads?
      credits = transaction_class.arel_table
      unexpired_credit = credits[:amount].gt(0).and(credits[:expires_at].eq(nil).or(credits[:expires_at].gt(at))).to_sql(transaction_class)
      debit = credits[:amount].lt(0).to_sql(transaction_class)
      remaining = remaining_amount_sql(lock: lock)
      reservations = current_read(wallet_holds.reservations.active(at: at), lock).select(hold_class.arel_table[:amount].sum)

      terms = [
        "COALESCE(SUM(CASE WHEN #{unexpired_credit} THEN #{remaining} ELSE 0 END), 0)",
        "COALESCE(SUM(CASE WHEN #{unexpired_credit} AND #{self.class.coverage_sql(at: at, lock: lock)} THEN #{remaining} ELSE 0 END), 0)",
        "(#{reservations.to_sql})",
        "COALESCE(SUM(CASE WHEN #{debit} THEN #{unbacked_amount_sql(lock: lock)} ELSE 0 END), 0)"
      ]

      # An unsaved wallet has no ledger to read: every term is zero.
      values = current_read(transactions, lock).pick(*terms.map { |sql| Arel.sql(sql) }) || []
      BalanceComponents.new(*Array.new(terms.size) { |index| values[index].to_i })
    end

    # P: the remaining value of unexpired credits, held or not. Kept with its
    # 0.3 signature and meaning (D12): embedders override it and call it.
    def positive_remaining_balance
      current_read(transactions.credits.not_expired(at: evaluation_time), current_reads?)
        .sum(remaining_amount_sql)
        .to_i
    end

    # N: the part of debits no credit backs. Kept with its 0.3 signature and
    # meaning (D12): usage_credits passes its own scope of debits.
    def unbacked_negative_balance(transaction_scope = transactions.debits)
      current_read(transaction_scope, current_reads?)
        .sum(unbacked_amount_sql)
        .to_i
    end

    # C and R, for telling a refused caller what holds keep out of reach.
    def held_and_reserved
      return [0, 0] unless holds_enabled?

      components = balance_components
      [components.covered, components.reserved]
    end

    # The buckets a debit may consume now: unexpired, and not covered by an
    # active hold (none at all while a wallet hold is active). The one
    # eligibility definition behind both affordability (through C) and
    # allocation, so the two can never disagree.
    def eligible_credits
      credits = transactions.credits.not_expired(at: evaluation_time)
      return credits unless holds_enabled?

      credits.where("NOT #{self.class.coverage_sql(at: evaluation_time, lock: current_reads?)}")
    end

    # P - C: what FEFO allocation can take from eligible buckets right now.
    def eligible_remaining_balance
      current_read(eligible_credits, current_reads?)
        .sum(remaining_amount_sql)
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

    # A debit's unbacked value: its size minus what credits allocated to it.
    def unbacked_amount_sql(lock: current_reads?)
      connection = transaction_class.connection
      txn_table = connection.quote_table_name(transaction_class.table_name)
      alloc_table = connection.quote_table_name(allocation_class.table_name)
      amount_column = connection.quote_column_name("amount")
      id_column = connection.quote_column_name("id")
      transaction_id_column = connection.quote_column_name("transaction_id")

      "ABS(#{txn_table}.#{amount_column}) - (SELECT COALESCE(SUM(#{amount_column}), 0) FROM #{alloc_table} WHERE #{transaction_id_column} = #{txn_table}.#{id_column}#{locking_clause(lock)})"
    end

    def wallet_holds
      hold_class.where(wallet_id: id)
    end

    # Writes the available balance to the cached column and returns it. Like
    # any cache it can go stale through time alone (expiry, lapsed deadlines),
    # so it is never authoritative for accounting.
    #
    # Every command increments `ledger_revision`, even when the balance did
    # not move (a second reason on a held credit, a capture of a whole
    # reservation): every committed change to the ledger must change the
    # wallet row, which is how `stale_snapshot?` knows a snapshot is current
    # (and how PostgreSQL's repeatable read detects a concurrent update on
    # `lock!`). `updated_at` then follows ordinary Rails rules and decides
    # nothing. A wallet table without the column (see `ledger_revision?`)
    # gets the timestamp marker instead, written with `update_column` when
    # the balance did not move, because `touch` writes nothing under
    # `no_touching`.
    #
    # `update!` rather than assigning and then saving, so nothing sits pending
    # between commands. A rollback can still leave these columns pending:
    # once the real transaction, or a savepoint the caller opened, rolls
    # back, Active Record restores the values this write left in memory as
    # unsaved changes. `lock!` discards exactly those (LEDGER_WRITTEN_COLUMNS)
    # before locking, so the next command can lock the wallet and reads the
    # row again.
    def refresh_cached_balance!
      available = current_balance

      refreshing_cached_balance do
        if ledger_revision?
          update!(balance: available, ledger_revision: ledger_revision + 1)
        elsif available == read_attribute(:balance)
          update_column(:updated_at, next_row_marker)
        else
          update!(balance: available, updated_at: next_row_marker)
        end
      end

      available
    end

    # The timestamp marker of a wallet table without `ledger_revision`: the
    # command's instant, or one microsecond past the current `updated_at`
    # when the clock has not moved past it (two commands within a
    # microsecond, a frozen clock), so no two commits leave the same row
    # behind. Assumes the column keeps microseconds, as `t.timestamps` does
    # from Rails 7 on (datetime(6)).
    def next_row_marker
      now = evaluation_time
      now = now.change(usec: now.usec) # the column's precision
      return now if updated_at.nil?

      [now, updated_at + MARKER_STEP].max
    end

    def refreshing_cached_balance
      @refreshing_cached_balance = true
      yield
    ensure
      @refreshing_cached_balance = false
    end

    def remember_own_write
      return if @refreshing_cached_balance || !self.class.current_reads_need_locks?

      remember_stale_snapshot!
    end

    # =========================================
    # Threshold Callbacks
    # =========================================

    # A refused funding attempt reports once, immediately (its transaction is
    # about to roll back), and names what holds keep out of reach, so the app
    # can say "20 available, 30 held, 50 reserved" rather than just "20".
    #
    # `available` is always the wallet's available balance, which nothing
    # moved. A command funded by something else says what it compared in
    # `comparison` (a capture counts its own reservation back in) and adds
    # the figures behind it to the metadata (`diagnostics`).
    def reject_insufficient_balance!(amount, available, metadata, comparison: "#{available} < #{amount}", **diagnostics)
      held, reserved = held_and_reserved
      dispatch_insufficient_balance!(amount, available, metadata, held: held, reserved: reserved, **diagnostics)

      details = {held: held, reserved: reserved}.reject { |_name, value| value.zero? }.map { |name, value| "#{value} #{name}" }
      raise InsufficientBalance, "Insufficient balance (#{comparison}#{"; #{details.join(", ")}" if details.any?})"
    end

    # `held:` is the credit value holds cover and `reserved:` the active
    # reservations, so available + held + reserved is the total balance.
    def dispatch_insufficient_balance!(amount, previous_balance, metadata, held: nil, reserved: nil, **diagnostics)
      held, reserved = held_and_reserved if held.nil? || reserved.nil?

      dispatch_callback(:insufficient,
        wallet: self,
        amount: amount,
        previous_balance: previous_balance,
        new_balance: previous_balance,
        metadata: metadata.merge(
          available: previous_balance,
          required: amount,
          held: held,
          reserved: reserved,
          **diagnostics
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
