# frozen_string_literal: true

require "test_helper"

# A command that is rolled back, by its own refusal or by the caller's
# transaction, must leave the wallet and hold instances it wrote usable: the
# next command on the same instance runs. Rails restores a rolled-back
# record's attributes to the values it had written, marked as unsaved
# changes, and refuses to lock a record with unsaved changes; every command
# starts with that lock. Real transactions, not the fixture transaction: inside
# a savepoint Rails does not restore the rolled-back values, so the trap only
# springs where production runs.
class RolledBackCommandTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @owner = users(:new_user)
    @wallet = create_wallet(@owner, asset_code: :rolled_back, initial_balance: 100)
  end

  teardown do
    Wallets::Wallet.where(asset_code: "rolled_back").find_each(&:destroy!)
  end

  test "a command refused after another wrote the wallet row leaves the instance usable" do
    # The shape of a block that spends inside a command (usage_credits'
    # spend_credits_on): the outer command locks the wallet, the inner debit
    # writes the cached balance, the outer refusal rolls it all back.
    assert_raises(Wallets::InsufficientBalance) do
      @wallet.with_lock(requires_new: true) do
        @wallet.debit(10, category: :purchase)
        @wallet.debit(1_000, category: :purchase)
      end
    end

    assert_equal 100, @wallet.balance
    assert_equal 100, Wallets::Wallet.find(@wallet.id).read_attribute(:balance), "read through another instance: a reload here would clear the very state under test"
    debit = @wallet.debit(10, category: :purchase)
    assert_equal(-10, debit.amount)
    assert_equal 90, @wallet.read_attribute(:balance), "the cached balance is written again"
    assert_equal 90, @wallet.reload.read_attribute(:balance)
  end

  test "a command after the caller's transaction rolled back leaves the instance usable" do
    error = assert_raises(RuntimeError) do
      @wallet.transaction do
        @wallet.debit(10, category: :purchase)
        raise "the caller's own failure"
      end
    end
    assert_equal "the caller's own failure", error.message

    credit = @wallet.credit(5, category: :purchase)
    assert_equal 5, credit.amount
    assert_equal 105, @wallet.reload.balance
  end

  test "a command inside the caller's transaction runs after a rolled-back savepoint in it" do
    @wallet.transaction do
      begin
        @wallet.transaction(requires_new: true) do
          @wallet.debit(10, category: :purchase)
          raise "a step the caller gives up on"
        end
      rescue RuntimeError
        # The caller carries on inside its transaction.
      end
      @wallet.debit(5, category: :purchase)
    end

    assert_equal 95, @wallet.reload.balance
    assert_equal 95, @wallet.read_attribute(:balance)
  end

  test "a transfer runs after a rolled-back command on either wallet" do
    other = create_wallet(users(:peer_user), asset_code: :rolled_back, initial_balance: 20)
    [@wallet, other].each do |wallet|
      assert_raises(RuntimeError) {
        wallet.transaction {
          wallet.debit(1, category: :purchase)
          raise "rolled back"
        }
      }
    end

    @wallet.transfer_to(other, 30)
    assert_equal [70, 50], [@wallet.reload.balance, other.reload.balance]
  end

  test "a hold is released after a rolled-back release on the same instance" do
    hold = @wallet.hold(@wallet.transactions.credits.sole, category: :fraud_review)
    assert_raises(RuntimeError) {
      @wallet.transaction {
        hold.release!(reason: "first try")
        raise "rolled back"
      }
    }
    assert Wallets::Hold.find(hold.id).active?, "read through another instance, so the retry runs on the dirty one"

    hold.release!(reason: "second try")
    assert_equal "second try", hold.reload.release_reason
    assert_equal 100, @wallet.reload.balance
  end

  test "a reservation is captured after a rolled-back capture on the same instance" do
    reservation = @wallet.reserve(60, category: :booking)
    assert_raises(RuntimeError) {
      @wallet.transaction {
        reservation.capture!(category: :purchase)
        raise "rolled back"
      }
    }
    assert Wallets::Hold.find(reservation.id).active?, "read through another instance, so the retry runs on the dirty one"

    debit = reservation.capture!(40, category: :purchase)
    assert_equal(-40, debit.amount)
    assert_equal 60, @wallet.reload.balance
    assert reservation.reload.captured?
  end

  test "the caller's own unsaved change is still refused by the lock" do
    @wallet.metadata = {"note" => "unsaved"}

    error = assert_raises(RuntimeError) { @wallet.debit(1, category: :purchase) }
    assert_match(/unpersisted changes/, error.message)
    assert_match(/"metadata"/, error.message)
  end
  test "the caller's own unsaved change on a hold is still refused by the lock" do
    hold = @wallet.hold(@wallet.transactions.credits.sole, category: :fraud_review)
    hold.metadata = {"note" => "unsaved"}

    error = assert_raises(RuntimeError) { hold.release!(reason: "cleared") }
    assert_match(/unpersisted changes/, error.message)
    assert_match(/"metadata"/, error.message)
    assert Wallets::Hold.find(hold.id).active?
  end

  test "locking an unsaved wallet or hold is a no-op, as in Rails" do
    wallet = Wallets::Wallet.new(owner: @owner, asset_code: :unsaved, balance: 5)
    assert_same wallet, wallet.lock!
    assert_equal 5, wallet.read_attribute(:balance), "nothing is discarded on a record that was never saved"

    hold = Wallets::Hold.new(wallet: @wallet, category: :x, release_reason: "set before save")
    assert_same hold, hold.lock!
    assert_equal "set before save", hold.release_reason
  end
end
