# frozen_string_literal: true

require "test_helper"

class Wallets::CallbackContextTest < ActiveSupport::TestCase
  test "exposes owner through the wallet and compacts hashes" do
    wallet = wallets_wallets(:rich_coins_wallet)
    context = Wallets::CallbackContext.new(
      event: :balance_credited,
      wallet: wallet,
      amount: 25,
      metadata: {source: "test"}
    )

    assert_equal wallet.owner, context.owner
    assert_equal(
      {
        event: :balance_credited,
        wallet: wallet,
        amount: 25,
        metadata: {source: "test"}
      },
      context.to_h
    )
  end

  test "carries the hold of hold events" do
    wallet = wallets_wallets(:rich_coins_wallet)
    hold = Wallets::Hold.new(wallet: wallet, category: :review)
    context = Wallets::CallbackContext.new(event: :hold_created, wallet: wallet, hold: hold, category: "review")

    assert_same hold, context.hold
    assert_equal({event: :hold_created, wallet: wallet, hold: hold, category: "review"}, context.to_h)
    assert_nil Wallets::CallbackContext.new(event: :balance_credited).hold
  end

  test "owner is nil without a wallet" do
    context = Wallets::CallbackContext.new(event: :balance_credited)

    assert_nil context.owner
    assert_equal({event: :balance_credited}, context.to_h)
  end
end
