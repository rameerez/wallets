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

    def low_balance_threshold=(value)
      @low_balance_threshold = value
    end

    def additional_categories=(value)
      @additional_categories = value
    end

    def transfer_expiration_policy=(value)
      @transfer_expiration_policy = value.to_sym
    end
  end

  module EmbeddedCallbacks
    @events = []

    class << self
      attr_accessor :events

      def dispatch(event, **data)
        @events << { event: event, data: data }
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

  class EmbeddedWallet < Wallets::Wallet
    self.embedded_table_name = "embedded_wallets"
    self.config_provider = -> { EmbeddabilityTest.embedded_config }
    self.callbacks_module = EmbeddabilityTest::EmbeddedCallbacks
    self.transaction_class_name = "EmbeddabilityTest::EmbeddedTransaction"
    self.allocation_class_name = "EmbeddabilityTest::EmbeddedAllocation"
    self.transfer_class_name = "EmbeddabilityTest::EmbeddedTransfer"
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

  class EmbeddedTransaction < Wallets::Transaction
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

  class EmbeddedAllocation < Wallets::Allocation
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

  class EmbeddedTransfer < Wallets::Transfer
    self.embedded_table_name = "embedded_transfers"
    self.config_provider = -> { EmbeddabilityTest.embedded_config }
    self.transaction_class_name = "EmbeddabilityTest::EmbeddedTransaction"

    belongs_to :from_wallet, class_name: "EmbeddabilityTest::EmbeddedWallet", inverse_of: :outgoing_transfers
    belongs_to :to_wallet, class_name: "EmbeddabilityTest::EmbeddedWallet", inverse_of: :incoming_transfers
    has_many :transactions,
             class_name: "EmbeddabilityTest::EmbeddedTransaction",
             foreign_key: :transfer_id,
             inverse_of: :transfer
  end

  ensure_embedded_tables!

  setup do
    EmbeddabilityTest.reset_embedded_config!
    EmbeddedCallbacks.reset!
    cleanup_embedded_records!
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

    wallet.credit(100, category: :embedded_reward, metadata: { source: "quest" })

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
            transfer = sender.transfer_to(recipient, 10, category: :peer_payment, metadata: { source: "embedded" })

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
      metadata: { source: "test", custom_ref: "abc123" },
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
      metadata: { item: "sword", order_id: 42 },
      source_reference: "ORDER-42"
    )

    assert transaction.persisted?
    assert_equal(-50, transaction.amount)
    assert_equal "sword", transaction.metadata["item"]
    assert_equal 42, transaction.metadata["order_id"]
    assert_equal "ORDER-42", transaction.source_reference
  end

  private

  def cleanup_embedded_records!
    [EmbeddedAllocation, EmbeddedTransaction, EmbeddedTransfer, EmbeddedWallet].each do |model|
      next unless model.table_exists?

      model.delete_all
    end
  end
end
