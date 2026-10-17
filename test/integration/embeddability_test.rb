# frozen_string_literal: true

require "test_helper"

# These tests verify that wallets can be embedded in another gem (like
# usage_credits) without global config collisions. The embedded classes use
# custom config, callbacks, table names, and model classes. Unlike simpler unit
# checks, these tests use real embedded tables and re-declared associations so
# we can prove the runtime behavior that embedded consumers rely on.
class EmbeddabilityTest < ActiveSupport::TestCase
  class EmbeddedConfig
    attr_accessor :allow_negative_balance
    attr_reader :table_prefix, :low_balance_threshold, :additional_categories, :transfer_expiration_policy

    def initialize
      @table_prefix = "embedded_"
      @allow_negative_balance = false
      @low_balance_threshold = 50
      @additional_categories = %w[embedded_reward embedded_charge]
      @transfer_expiration_policy = :preserve
    end

    attr_writer :low_balance_threshold

    attr_writer :additional_categories

    def transfer_expiration_policy=(value)
      @transfer_expiration_policy = value.to_sym
    end
  end

  module EmbeddedCallbacks
    @events = []

    class << self
      attr_accessor :events

      def dispatch(event, **data)
        @events << {event: event, data: data}
      end

      def reset!
        @events = []
      end
    end
  end

  class << self
    attr_writer :embedded_config

    def embedded_config
      @embedded_config ||= EmbeddedConfig.new
    end

    def reset_embedded_config!
      self.embedded_config = EmbeddedConfig.new
    end

    def ensure_embedded_tables!
      return if embedded_tables_ready?

      rebuild_embedded_tables!
    end

    private

    def embedded_tables_ready?
      connection = ActiveRecord::Base.connection
      connection.data_source_exists?("embedded_wallets") &&
        connection.data_source_exists?("embedded_transactions") &&
        connection.data_source_exists?("embedded_transfers") &&
        connection.data_source_exists?("embedded_allocations") &&
        connection.column_exists?(:embedded_transfers, :expiration_policy) &&
        connection.column_exists?(:embedded_transactions, :source_reference)
    end

    def rebuild_embedded_tables!
      connection = ActiveRecord::Base.connection

      %i[embedded_allocations embedded_transactions embedded_transfers embedded_wallets].each do |table_name|
        connection.drop_table(table_name, if_exists: true)
      end

      connection.create_table :embedded_wallets do |t|
        t.references :owner, polymorphic: true, null: false
        t.string :asset_code, null: false
        t.bigint :balance, null: false, default: 0
        t.public_send(json_column_type(connection), :metadata, null: false, default: json_column_default(connection))
        t.timestamps
      end
      connection.add_index :embedded_wallets, [:owner_type, :owner_id, :asset_code], unique: true, name: "index_embedded_wallets_on_owner_and_asset_code"

      connection.create_table :embedded_transfers do |t|
        t.integer :from_wallet_id, null: false
        t.integer :to_wallet_id, null: false
        t.string :asset_code, null: false
        t.bigint :amount, null: false
        t.string :category, null: false, default: "transfer"
        t.string :expiration_policy, null: false, default: "preserve"
        t.public_send(json_column_type(connection), :metadata, null: false, default: json_column_default(connection))
        t.timestamps
      end

      connection.create_table :embedded_transactions do |t|
        t.integer :wallet_id, null: false
        t.bigint :amount, null: false
        t.string :category, null: false
        t.datetime :expires_at
        t.integer :transfer_id
        t.string :source_reference
        t.public_send(json_column_type(connection), :metadata, null: false, default: json_column_default(connection))
        t.timestamps
      end

      connection.create_table :embedded_allocations do |t|
        t.integer :transaction_id, null: false
        t.integer :source_transaction_id, null: false
        t.bigint :amount, null: false
        t.timestamps
      end

      [EmbeddedWallet, EmbeddedTransaction, EmbeddedTransfer, EmbeddedAllocation].each(&:reset_column_information)
    end

    def json_column_type(connection)
      connection.adapter_name.downcase.include?("postgresql") ? :jsonb : :json
    end

    def json_column_default(connection)
      connection.adapter_name.downcase.include?("mysql") ? nil : {}
    end
  end

  class EmbeddedWallet < Wallets::WalletBase
    self.embedded_table_name = "embedded_wallets"
    self.config_provider = -> { EmbeddabilityTest.embedded_config }
    self.callbacks_module = EmbeddabilityTest::EmbeddedCallbacks
    self.transaction_class_name = "EmbeddabilityTest::EmbeddedTransaction"
    self.allocation_class_name = "EmbeddabilityTest::EmbeddedAllocation"
    self.transfer_class_name = "EmbeddabilityTest::EmbeddedTransfer"
    self.additional_transaction_attribute_names = %i[source_reference].freeze
    self.callback_event_map = {
      credited: :embedded_credited,
      debited: :embedded_debited,
      insufficient: :embedded_insufficient,
      low_balance: :embedded_low_balance,
      depleted: :embedded_depleted,
      transfer_completed: :embedded_transfer_completed
    }.freeze

    has_many :transactions,
      class_name: "EmbeddabilityTest::EmbeddedTransaction",
      foreign_key: :wallet_id,
      dependent: :destroy,
      inverse_of: :wallet
    has_many :outgoing_transfers,
      class_name: "EmbeddabilityTest::EmbeddedTransfer",
      foreign_key: :from_wallet_id,
      dependent: :destroy,
      inverse_of: :from_wallet
    has_many :incoming_transfers,
      class_name: "EmbeddabilityTest::EmbeddedTransfer",
      foreign_key: :to_wallet_id,
      dependent: :destroy,
      inverse_of: :to_wallet
  end

  class EmbeddedTransaction < Wallets::TransactionBase
    self.embedded_table_name = "embedded_transactions"
    self.config_provider = -> { EmbeddabilityTest.embedded_config }

    belongs_to :wallet, class_name: "EmbeddabilityTest::EmbeddedWallet", inverse_of: :transactions
    belongs_to :transfer, class_name: "EmbeddabilityTest::EmbeddedTransfer", optional: true, inverse_of: :transactions

    has_many :outgoing_allocations,
      class_name: "EmbeddabilityTest::EmbeddedAllocation",
      foreign_key: :transaction_id,
      dependent: :destroy,
      inverse_of: :spend_transaction
    has_many :incoming_allocations,
      class_name: "EmbeddabilityTest::EmbeddedAllocation",
      foreign_key: :source_transaction_id,
      dependent: :destroy,
      inverse_of: :source_transaction
  end

  class EmbeddedAllocation < Wallets::AllocationBase
    self.embedded_table_name = "embedded_allocations"
    self.config_provider = -> { EmbeddabilityTest.embedded_config }

    belongs_to :spend_transaction,
      class_name: "EmbeddabilityTest::EmbeddedTransaction",
      foreign_key: :transaction_id,
      inverse_of: :outgoing_allocations
    belongs_to :source_transaction,
      class_name: "EmbeddabilityTest::EmbeddedTransaction",
      foreign_key: :source_transaction_id,
      inverse_of: :incoming_allocations
  end

  class EmbeddedTransfer < Wallets::TransferBase
    self.embedded_table_name = "embedded_transfers"
    self.config_provider = -> { EmbeddabilityTest.embedded_config }
    self.transaction_class_name = "EmbeddabilityTest::EmbeddedTransaction"

    belongs_to :from_wallet, class_name: "EmbeddabilityTest::EmbeddedWallet", inverse_of: :outgoing_transfers
    belongs_to :to_wallet, class_name: "EmbeddabilityTest::EmbeddedWallet", inverse_of: :incoming_transfers
    has_many :transactions,
      class_name: "EmbeddabilityTest::EmbeddedTransaction",
      foreign_key: :transfer_id,
      inverse_of: :transfer,
      dependent: :nullify
  end

  ensure_embedded_tables!

  setup do
    EmbeddabilityTest.reset_embedded_config!
    EmbeddedCallbacks.reset!
    cleanup_embedded_records!
  end

  test "embedded classes are their own base_class so the base tables are never consulted" do
    # Regression guard for the fresh-install crash: ActiveRecord builds a
    # subclass's attribute methods on its parent's (`superclass.
    # define_attribute_methods unless base_class?`), so embedding under a
    # CONCRETE parent forces a schema load of the wallets_* tables — which
    # don't exist in apps that only run an embedded ledger. Subclassing the
    # abstract *Base classes makes every embedded model its own base_class.
    [EmbeddedWallet, EmbeddedTransaction, EmbeddedAllocation, EmbeddedTransfer].each do |model|
      assert_equal model, model.base_class,
        "#{model} must be its own base_class (abstract parent), or fresh embedded-only installs crash"
      assert_predicate model.superclass, :abstract_class?,
        "#{model}'s parent must be abstract so AR never loads the base wallets_* schema"
    end

    # The standalone concrete models keep working exactly as before.
    [Wallets::Wallet, Wallets::Transaction, Wallets::Allocation, Wallets::Transfer].each do |model|
      assert_equal model, model.base_class
    end
  end

  test "embedded classes use custom config provider" do
    config = EmbeddedWallet.resolved_config

    assert_equal "embedded_", config.table_prefix
    assert_equal 50, config.low_balance_threshold
    assert_equal :preserve, config.transfer_expiration_policy
    assert_includes config.additional_categories, "embedded_reward"
  end

  test "embedded classes use custom callback module" do
    assert_equal EmbeddedCallbacks, EmbeddedWallet.callbacks_module
    assert_equal Wallets::Callbacks, Wallets::Wallet.callbacks_module
  end

  test "embedded allowlists cannot reopen core accounting attributes" do
    original = EmbeddedWallet.additional_transaction_attribute_names
    EmbeddedWallet.additional_transaction_attribute_names = %i[source_reference amount]
    wallet = EmbeddedWallet.create!(owner: users(:new_user), asset_code: "points")

    error = assert_raises(ArgumentError) do
      wallet.credit(10, amount: 1_000_000)
    end

    assert_includes error.message, "amount"
    assert_empty wallet.transactions
  ensure
    EmbeddedWallet.additional_transaction_attribute_names = original
  end

  test "embedded table names derive from config prefix and model suffix when not set explicitly" do
    derived_wallet_class = Class.new(Wallets::Wallet) do
      self.config_provider = -> { EmbeddabilityTest.embedded_config }
    end
    derived_transaction_class = Class.new(Wallets::Transaction) do
      self.config_provider = -> { EmbeddabilityTest.embedded_config }
    end

    assert_equal "embedded_wallets", derived_wallet_class.table_name
    assert_equal "embedded_transactions", derived_transaction_class.table_name
  end

  test "config_provider accepts a plain config object as well as a callable" do
    config_instance = EmbeddedConfig.new
    direct_config_class = Class.new(Wallets::Wallet)
    direct_config_class.config_provider = config_instance

    assert_same config_instance, direct_config_class.resolved_config
    assert_equal "embedded_wallets", direct_config_class.table_name
  end

  test "events missing from the callback event map are silently skipped" do
    silent_wallet_class = Class.new(EmbeddedWallet) do
      def self.name
        "EmbeddabilityTest::SilentWallet"
      end

      self.callback_event_map = {debited: :embedded_debited}.freeze
    end

    wallet = silent_wallet_class.create_for_owner!(owner: users(:new_user), asset_code: :silent_asset)
    wallet.credit(50, category: :embedded_reward)

    assert_empty EmbeddedCallbacks.events, "unmapped credited event must not dispatch"

    wallet.debit(10, category: :embedded_charge)

    assert_equal [:embedded_debited], EmbeddedCallbacks.events.map { |event| event[:event] }
  end

  test "embedded table names are used at runtime" do
    wallet = nil

    assert_difference -> { EmbeddedWallet.count }, 1 do
      assert_difference -> { EmbeddedTransaction.count }, 1 do
        assert_no_difference -> { Wallets::Wallet.count } do
          assert_no_difference -> { Wallets::Transaction.count } do
            wallet = EmbeddedWallet.create_for_owner!(
              owner: users(:new_user),
              asset_code: :embedded_points,
              initial_balance: 25
            )
          end
        end
      end
    end

    assert_equal "embedded_wallets", EmbeddedWallet.table_name
    assert_equal "embedded_transactions", EmbeddedTransaction.table_name
    assert_equal "embedded_transfers", EmbeddedTransfer.table_name
    assert_equal 1, EmbeddedWallet.where(owner: users(:new_user), asset_code: "embedded_points").count
    assert_equal 1, EmbeddedTransaction.where(wallet_id: wallet.id).count
    assert_nil Wallets::Wallet.find_by(owner: users(:new_user), asset_code: "embedded_points")
  end

  test "embedded wallet operations dispatch to the embedded callback module" do
    wallet = EmbeddedWallet.create_for_owner!(
      owner: users(:new_user),
      asset_code: :callback_test,
      initial_balance: 0
    )

    wallet.credit(100, category: :embedded_reward, metadata: {source: "quest"})

    assert_equal 1, EmbeddedCallbacks.events.size
    assert_equal :embedded_credited, EmbeddedCallbacks.events.first[:event]
    assert_equal 100, EmbeddedCallbacks.events.first[:data][:amount]
    assert_instance_of EmbeddedWallet, EmbeddedCallbacks.events.first[:data][:wallet]
    assert_equal "quest", EmbeddedCallbacks.events.first[:data][:metadata][:source]
  end

  test "embedded transfers create embedded records only" do
    sender = EmbeddedWallet.create_for_owner!(owner: users(:rich_user), asset_code: :transfer_test, initial_balance: 100)
    recipient = EmbeddedWallet.create_for_owner!(owner: users(:peer_user), asset_code: :transfer_test, initial_balance: 0)

    assert_difference -> { EmbeddedTransfer.count }, 1 do
      assert_difference -> { EmbeddedTransaction.count }, 2 do
        assert_no_difference -> { Wallets::Transfer.count } do
          assert_no_difference -> { Wallets::Transaction.count } do
            transfer = sender.transfer_to(recipient, 10, category: :peer_payment, metadata: {source: "embedded"})

            assert_instance_of EmbeddedTransfer, transfer
            assert_instance_of EmbeddedTransaction, transfer.outbound_transaction
            assert_equal [EmbeddedTransaction], transfer.inbound_transactions.map(&:class).uniq
            assert_equal 1, transfer.inbound_transactions.count
            assert_equal 90, sender.reload.balance
            assert_equal 10, recipient.reload.balance
            assert_equal "embedded", transfer.metadata["source"]
            assert_equal "preserve", transfer.expiration_policy
          end
        end
      end
    end
  end

  test "cross-class transfers are rejected with real embedded wallets" do
    base_wallet = create_wallet(users(:rich_user), asset_code: :shared_asset, initial_balance: 100)
    embedded_wallet = EmbeddedWallet.create_for_owner!(owner: users(:peer_user), asset_code: :shared_asset, initial_balance: 50)

    error = assert_raises(Wallets::InvalidTransfer) do
      base_wallet.transfer_to(embedded_wallet, 10, category: :peer_payment)
    end
    assert_equal "Wallet classes must match", error.message

    error = assert_raises(Wallets::InvalidTransfer) do
      embedded_wallet.transfer_to(base_wallet, 10, category: :peer_payment)
    end
    assert_equal "Wallet classes must match", error.message
  end

  test "credit accepts and persists extra transaction attributes on embedded subclasses" do
    wallet = EmbeddedWallet.create_for_owner!(owner: users(:new_user), asset_code: :extra_attrs, initial_balance: 0)

    transaction = wallet.credit(
      100,
      category: :embedded_reward,
      metadata: {source: "test", custom_ref: "abc123"},
      source_reference: "FULFILLMENT-123"
    )

    assert transaction.persisted?
    assert_equal 100, transaction.amount
    assert_equal "test", transaction.metadata["source"]
    assert_equal "abc123", transaction.metadata["custom_ref"]
    assert_equal "FULFILLMENT-123", transaction.source_reference
    assert_equal "FULFILLMENT-123", EmbeddedTransaction.find(transaction.id).source_reference
  end

  test "debit accepts and persists extra transaction attributes on embedded subclasses" do
    wallet = EmbeddedWallet.create_for_owner!(owner: users(:new_user), asset_code: :extra_attrs_debit, initial_balance: 100)

    transaction = wallet.debit(
      50,
      category: :embedded_charge,
      metadata: {item: "sword", order_id: 42},
      source_reference: "ORDER-42"
    )

    assert transaction.persisted?
    assert_equal(-50, transaction.amount)
    assert_equal "sword", transaction.metadata["item"]
    assert_equal 42, transaction.metadata["order_id"]
    assert_equal "ORDER-42", transaction.source_reference
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Holds are opt-in: this embedded ledger never enabled them
  # ───────────────────────────────────────────────────────────────────────────

  test "an embedded ledger keeps no holds unless it opts in" do
    refute EmbeddedWallet.holds_enabled?
    assert_nil EmbeddedWallet.hold_class_name
    assert_raises(Wallets::HoldsNotEnabled) { EmbeddedWallet.hold_class }
    refute EmbeddedTransaction.reflect_on_association(:holds), "hold associations belong to opted-in classes only"
    refute EmbeddedWallet.reflect_on_association(:holds)
  end

  test "a ledger without holds never touches a holds table, destroy included" do
    sender = EmbeddedWallet.create_for_owner!(owner: users(:rich_user), asset_code: :plain_points, initial_balance: 100)
    recipient = EmbeddedWallet.create_for_owner!(owner: users(:peer_user), asset_code: :plain_points)
    EmbeddabilityTest.embedded_config.allow_negative_balance = true

    statements = capture_sql do
      credit = sender.credit(50, category: :embedded_reward, expires_at: 10.days.from_now)
      debit = sender.debit(30, category: :embedded_charge)
      sender.transfer_to(recipient, 40, category: :peer_payment)
      sender.debit(500, category: :embedded_charge)
      EmbeddabilityTest.embedded_config.allow_negative_balance = false
      assert_raises(Wallets::InsufficientBalance) { sender.debit(10, category: :embedded_charge) }

      [sender, recipient].each do |wallet|
        wallet.balance
        wallet.available_balance
        wallet.held_balance
        wallet.total_balance
        wallet.on_hold?
        wallet.has_enough_balance?(1)
      end
      [credit, debit].each do |transaction|
        transaction.held_amount
        transaction.available_amount
        transaction.held?
      end

      recipient.destroy!
      sender.destroy!
    end

    assert statements.any? { |sql| sql.match?(/embedded_transactions/) }, "the capture saw the ledger's own queries"
    hold_statements = statements.grep(/holds/i)
    assert_empty hold_statements, "a ledger without holds ran hold SQL:\n#{hold_statements.join("\n")}"
  end

  test "readers without holds delegate to the ledger's own balance policy" do
    # usage_credits overrides `current_balance` (its refund debt stays
    # ledger debt, its public balance is floored at zero). Without holds,
    # available and total balance must be that very number.
    floored = Class.new(EmbeddedWallet) do
      def self.name
        "EmbeddabilityTest::FlooredWallet"
      end

      def current_balance
        [positive_remaining_balance - unbacked_negative_balance(transactions.debits.where(category: "embedded_charge")), 0].max
      end
    end
    EmbeddabilityTest.embedded_config.allow_negative_balance = true
    wallet = floored.create_for_owner!(owner: users(:new_user), asset_code: :floored, initial_balance: 10)
    wallet.debit(25, category: :embedded_charge)

    statements = capture_sql do
      assert_equal 0, wallet.balance
      assert_equal 0, wallet.available_balance
      assert_equal 0, wallet.total_balance
      assert_equal 0, wallet.held_balance
      refute wallet.on_hold?
    end

    assert_empty statements.grep(/holds/i)
    assert_equal 0, wallet.reload.read_attribute(:balance), "the override also decides the cached balance"
  end

  test "insufficient_balance on a ledger without holds reports nothing held or reserved" do
    wallet = EmbeddedWallet.create_for_owner!(owner: users(:new_user), asset_code: :short, initial_balance: 5)

    error = assert_raises(Wallets::InsufficientBalance) { wallet.debit(10, category: :embedded_charge) }

    assert_equal "Insufficient balance (5 < 10)", error.message
    event = EmbeddedCallbacks.events.find { |entry| entry[:event] == :embedded_insufficient }
    assert_equal 0, event[:data][:metadata][:held]
    assert_equal 0, event[:data][:metadata][:reserved]
  end

  private

  def cleanup_embedded_records!
    [EmbeddedAllocation, EmbeddedTransaction, EmbeddedTransfer, EmbeddedWallet].each do |model|
      next unless model.table_exists?

      model.delete_all
    end
  end
end
