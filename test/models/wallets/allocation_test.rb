# frozen_string_literal: true

require "test_helper"

class Wallets::AllocationTest < ActiveSupport::TestCase
  test "belongs to spend and source transactions" do
    allocation = wallets_allocations(:rich_purchase_allocation)

    assert_equal wallets_transactions(:rich_purchase), allocation.spend_transaction
    assert_equal wallets_transactions(:rich_top_up), allocation.source_transaction
  end

  test "prevents allocating more than the source transaction has remaining" do
    allocation = Wallets::Allocation.new(
      spend_transaction: wallets_transactions(:rich_purchase),
      source_transaction: wallets_transactions(:rich_top_up),
      amount: 1_000
    )

    assert_not allocation.valid?
    assert_includes allocation.errors.full_messages.join, "remaining amount"
  end

  test "prevents allocations across different wallets" do
    allocation = Wallets::Allocation.new(
      spend_transaction: wallets_transactions(:rich_purchase),
      source_transaction: wallets_transactions(:peer_top_up),
      amount: 10
    )

    assert_not allocation.valid?
    assert_includes allocation.errors.full_messages.join, "same wallet"
  end

  test "validation guards tolerate missing associations" do
    allocation = Wallets::Allocation.new(amount: 5)

    refute allocation.valid?
    assert allocation.errors[:spend_transaction].any?
    assert allocation.errors[:source_transaction].any?
  end

  test "requires a positive whole amount" do
    allocation = Wallets::Allocation.new(
      spend_transaction: wallets_transactions(:rich_purchase),
      source_transaction: wallets_transactions(:rich_top_up)
    )

    [nil, 0, -5, 2.5].each do |bad_amount|
      allocation.amount = bad_amount

      assert_not allocation.valid?, "expected amount=#{bad_amount.inspect} to be invalid"
    end

    allocation.amount = 10
    assert allocation.valid?
  end
end
