# frozen_string_literal: true

require "test_helper"

class Wallets::ConfigurationTest < ActiveSupport::TestCase
  test "initializes with sensible defaults" do
    configuration = Wallets::Configuration.new

    assert_equal :credits, configuration.default_asset
    assert_equal [], configuration.additional_categories
    assert_equal false, configuration.allow_negative_balance
    assert_nil configuration.low_balance_threshold
    assert_equal "wallets_", configuration.table_prefix
    assert_equal :preserve, configuration.transfer_expiration_policy
    assert_nil configuration.on_balance_credited_callback
    assert_nil configuration.on_balance_debited_callback
    assert_nil configuration.on_transfer_completed_callback
    assert_nil configuration.on_low_balance_reached_callback
    assert_nil configuration.on_balance_depleted_callback
    assert_nil configuration.on_insufficient_balance_callback
  end

  test "normalizes and validates configuration values" do
    configuration = Wallets::Configuration.new

    configuration.default_asset = " EUR "
    configuration.additional_categories = [" quest_reward ", :quest_reward, "", "marketplace_sale"]
    configuration.low_balance_threshold = "25"
    configuration.table_prefix = "custom_"
    configuration.transfer_expiration_policy = "none"

    assert_equal :eur, configuration.default_asset
    assert_equal ["quest_reward", "marketplace_sale"], configuration.additional_categories
    assert_equal 25, configuration.low_balance_threshold
    assert_equal "custom_", configuration.table_prefix
    assert_equal :none, configuration.transfer_expiration_policy
  end

  test "runtime model table names follow the configured table prefix" do
    configuration = Wallets::Configuration.new
    configuration.table_prefix = "ledger_"

    Wallets.stub(:configuration, configuration) do
      assert_equal "ledger_wallets", Wallets::Wallet.table_name
      assert_equal "ledger_transactions", Wallets::Transaction.table_name
      assert_equal "ledger_allocations", Wallets::Allocation.table_name
      assert_equal "ledger_transfers", Wallets::Transfer.table_name
    end
  end

  test "rejects invalid configuration values" do
    configuration = Wallets::Configuration.new

    assert_raises(ArgumentError) { configuration.default_asset = "   " }
    assert_raises(ArgumentError) { configuration.additional_categories = "reward" }
    assert_raises(ArgumentError) { configuration.low_balance_threshold = -1 }
    assert_raises(ArgumentError) { configuration.table_prefix = "" }
    assert_raises(ArgumentError) { configuration.transfer_expiration_policy = :fixed }
  end

  test "stores lifecycle callback blocks" do
    configuration = Wallets::Configuration.new
    credited = -> {}
    debited = -> {}
    transferred = -> {}
    low_balance = -> {}
    depleted = -> {}
    insufficient = -> {}

    configuration.on_balance_credited(&credited)
    configuration.on_balance_debited(&debited)
    configuration.on_transfer_completed(&transferred)
    configuration.on_low_balance_reached(&low_balance)
    configuration.on_balance_depleted(&depleted)
    configuration.on_insufficient_balance(&insufficient)

    assert_equal credited, configuration.on_balance_credited_callback
    assert_equal debited, configuration.on_balance_debited_callback
    assert_equal transferred, configuration.on_transfer_completed_callback
    assert_equal low_balance, configuration.on_low_balance_reached_callback
    assert_equal depleted, configuration.on_balance_depleted_callback
    assert_equal insufficient, configuration.on_insufficient_balance_callback
  end
end
