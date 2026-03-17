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
  end
end
