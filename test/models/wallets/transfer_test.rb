# frozen_string_literal: true

require "test_helper"

class Wallets::TransferTest < ActiveSupport::TestCase
  test "transfers value between wallets of the same asset" do
    source_wallet = wallets_wallets(:rich_coins_wallet)
    target_wallet = wallets_wallets(:peer_coins_wallet)

    transfer = source_wallet.transfer_to(
      target_wallet,
      250,
      category: :peer_payment,
      metadata: { note: "Thanks for the help" }
    )

    assert transfer.persisted?
    assert_equal "coins", transfer.asset_code
    assert_equal 250, transfer.amount
    assert_equal 750, source_wallet.reload.balance
    assert_equal 370, target_wallet.reload.balance
    assert_equal transfer.id, transfer.outbound_transaction.transfer_id
    assert_equal transfer.id, transfer.inbound_transaction.transfer_id
    assert_equal "peer_payment", transfer.category
  end

  test "rejects transfers across different assets" do
    source_wallet = wallets_wallets(:rich_coins_wallet)
    target_wallet = wallets_wallets(:rich_gems_wallet)

    assert_raises(Wallets::InvalidTransfer) do
      source_wallet.transfer_to(target_wallet, 10, category: :peer_payment)
    end
  end

  test "transfer model rejects the same wallet on both sides" do
    wallet = wallets_wallets(:rich_coins_wallet)

    transfer = Wallets::Transfer.new(
      from_wallet: wallet,
      to_wallet: wallet,
      asset_code: :coins,
      amount: 10
    )

    refute transfer.valid?
    assert_includes transfer.errors[:to_wallet], "must be different from from_wallet"
  end
end
