# frozen_string_literal: true

require "test_helper"

class HasWalletsTest < ActiveSupport::TestCase
  test "auto-creates the main wallet on owner creation" do
    user = User.create!(email: "auto@example.com", name: "Auto User")

    assert user.main_wallet.persisted?
    assert_equal "coins", user.main_wallet.asset_code
    assert_equal user, user.main_wallet.owner
  end

  test "wallet returns the main wallet when no asset is given" do
    user = users(:rich_user)

    assert_equal user.main_wallet, user.wallet
    assert_equal "coins", user.wallet.asset_code
  end

  test "wallet creates additional asset wallets on demand" do
    user = users(:new_user)

    gems_wallet = user.wallet(:gems)

    assert gems_wallet.persisted?
    assert_equal "gems", gems_wallet.asset_code
    assert_equal user, gems_wallet.owner
  end

  test "initial_balance only applies to the default asset wallet" do
    test_class = Class.new(User) do
      def self.name
        "SeededWalletUser"
      end

      has_wallets default_asset: :coins, initial_balance: 25
    end

    user = test_class.create!(email: "seeded@example.com", name: "Seeded User")

    assert_equal 25, user.main_wallet.balance
    assert_equal 0, user.wallet(:gems).balance
  end

  test "auto_create can be disabled" do
    test_class = Class.new(User) do
      def self.name
        "WalletlessUser"
      end

      has_wallets auto_create: false
    end

    user = test_class.create!(email: "walletless@example.com", name: "Walletless User")

    assert_nil user.find_wallet(:coins)
    assert_nil user.wallet(:coins), "wallet lookup must not auto-create when disabled"
    assert_nil user.main_wallet
    refute user.wallet?
  end

  test "wallet? reports existence without creating wallets" do
    user = users(:new_user)

    assert_no_difference -> { Wallets::Wallet.count } do
      refute user.wallet?(:never_created)
    end

    user.wallet(:now_created)

    assert user.wallet?(:now_created)
    assert user.wallet?(" NOW_CREATED "), "asset codes are normalized on lookup"
    assert user.wallet?, "defaults to the default asset wallet"
  end

  test "find_wallet returns nil instead of creating and normalizes the asset code" do
    user = users(:new_user)

    assert_nil user.find_wallet(:missing)

    wallet = user.wallet(:gems)

    assert_equal wallet, user.find_wallet(" GEMS ")
    assert_equal user.main_wallet, user.find_wallet
  end

  test "wallet raises a Wallets::Error for unsaved owners" do
    user = User.new(email: "unsaved@example.com", name: "Unsaved")

    error = assert_raises(Wallets::Error) { user.wallet(:coins) }
    assert_includes error.message, "unsaved"
  end

  test "owner creation auto-creates the main wallet inside the same transaction" do
    user = nil
    ActiveRecord::Base.transaction do
      user = User.create!(email: "txn-#{SecureRandom.hex(4)}@example.com", name: "Txn User")

      assert user.wallet?(:coins), "wallet exists before the outer transaction commits"
    end

    assert user.main_wallet.persisted?
  end

  test "subclasses inherit their parent's wallet options" do
    parent_class = Class.new(User) do
      def self.name
        "ParentWithWallets"
      end

      has_wallets default_asset: :doubloons, initial_balance: 5
    end

    child_class = Class.new(parent_class) do
      def self.name
        "ChildOfParentWithWallets"
      end
    end

    assert_equal :doubloons, child_class.wallet_options[:default_asset]

    child = child_class.create!(email: "child@example.com", name: "Child")

    assert_equal "doubloons", child.main_wallet.asset_code
    assert_equal 5, child.main_wallet.balance
  end

  test "subclasses can override their parent's wallet options" do
    parent_class = Class.new(User) do
      def self.name
        "OverridableParent"
      end

      has_wallets default_asset: :gold
    end

    child_class = Class.new(parent_class) do
      def self.name
        "OverridingChild"
      end

      has_wallets default_asset: :silver
    end

    assert_equal :silver, child_class.wallet_options[:default_asset]
    assert_equal :gold, parent_class.wallet_options[:default_asset], "the parent keeps its own options"
  end

  test "wallet_options returns pure defaults for models that never declared has_wallets" do
    options = ActiveRecord::Base.wallet_options

    assert_equal :coins, options[:default_asset]
    assert_equal true, options[:auto_create]
    assert_equal 0, options[:initial_balance]
  end

  test "models without explicit options follow the configured default asset lazily" do
    test_class = Class.new(User) do
      def self.name
        "LazyDefaultUser"
      end

      has_wallets
    end

    assert_equal :coins, test_class.wallet_options[:default_asset]

    Wallets.configuration.default_asset = :stars

    assert_equal :stars, test_class.wallet_options[:default_asset],
      "config changes apply without re-declaring has_wallets"
  end
end
