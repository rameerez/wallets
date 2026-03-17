# frozen_string_literal: true

require "test_helper"

class Wallets::CallbackContextTest < ActiveSupport::TestCase
  test "exposes owner through the wallet and compacts hashes" do
    wallet = wallets_wallets(:rich_coins_wallet)
    context = Wallets::CallbackContext.new(
      event: :balance_credited,
      wallet: wallet,
      amount: 25,
      metadata: { source: "test" }
    )

    assert_equal wallet.owner, context.owner
    assert_equal(
      {
        event: :balance_credited,
        wallet: wallet,
        amount: 25,
        metadata: { source: "test" }
      },
      context.to_h
    )
  end
end
