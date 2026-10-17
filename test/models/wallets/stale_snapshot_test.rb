# frozen_string_literal: true

require "test_helper"

# How long a stale-snapshot verdict lasts, and what makes one, on every
# adapter. A verdict is about the real database transaction's snapshot, so it
# must outlive every savepoint inside it, `transaction(joinable: false)`
# boundaries included, and end exactly when that transaction does. Real
# transactions need real commits, so this class runs without transactional
# fixtures and cleans up after itself. MySQL is the only adapter that needs the
# verdict at all; the stub stands in for it here, and CurrentReadsTest proves
# the interleavings on MySQL itself.
class Wallets::StaleSnapshotTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @owner = User.create!(email: "stale-#{SecureRandom.hex(6)}@example.com", name: "Stale Snapshot")
    @wallet = create_wallet(@owner, asset_code: :stale, initial_balance: 100)
  end

  teardown do
    Wallets::Wallet.unstub(:current_reads_need_locks?)
    @owner&.destroy!
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The end of the real transaction
  # ───────────────────────────────────────────────────────────────────────────

  test "the end-of-transaction hook waits for the real commit, through every savepoint" do
    [true, false].each do |joinable|
      ended = []

      connection.transaction(joinable: joinable) do
        connection.transaction(requires_new: true) do
          at_end_of_real_transaction { ended << :ended }
        end
        assert_empty ended, "a released savepoint is not the end (joinable: #{joinable})"

        connection.transaction(requires_new: true) { raise ActiveRecord::Rollback }
        assert_empty ended
      end

      assert_equal [:ended], ended, "the real commit is (joinable: #{joinable})"
    end
  end

  test "the end-of-transaction hook runs once when the real transaction rolls back, not when a savepoint does" do
    ended = []

    connection.transaction(joinable: false) do
      connection.transaction(requires_new: true) do
        at_end_of_real_transaction { ended << :ended }
        raise ActiveRecord::Rollback
      end
      assert_empty ended, "a rolled-back savepoint is not the end"

      raise ActiveRecord::Rollback
    end

    assert_equal [:ended], ended
  end

  test "outside a transaction the end-of-transaction hook runs at once" do
    ended = []

    at_end_of_real_transaction { ended << :ended }

    assert_equal [:ended], ended
  end

  # ───────────────────────────────────────────────────────────────────────────
  # The verdict's lifetime
  # ───────────────────────────────────────────────────────────────────────────

  test "a stale verdict outlives savepoints, ends with the real transaction, and is not inherited by the next" do
    Wallets::Wallet.stubs(:current_reads_need_locks?).returns(true)
    verdicts = {}

    Wallets::Wallet.transaction(joinable: false) do
      @wallet.lock!
      @wallet.updated_at += 1.second # the lock returned a row the snapshot has not seen
      assert @wallet.send(:stale_snapshot?)
      @wallet.restore_attributes

      Wallets::Wallet.transaction(requires_new: true) { verdicts[:savepoint_released] = @wallet.send(:stale_snapshot?) }
      Wallets::Wallet.transaction(requires_new: true) do
        verdicts[:inside_a_savepoint_rolled_back] = @wallet.send(:stale_snapshot?)
        raise ActiveRecord::Rollback
      end
      verdicts[:after_a_rolled_back_savepoint] = @wallet.send(:stale_snapshot?)
    end
    verdicts[:after_the_commit] = remembered_stale_snapshots.any?

    Wallets::Wallet.transaction do
      @wallet.lock!
      verdicts[:next_transaction] = @wallet.send(:stale_snapshot?)
    end

    assert_equal(
      {savepoint_released: true, inside_a_savepoint_rolled_back: true, after_a_rolled_back_savepoint: true, after_the_commit: false, next_transaction: false},
      verdicts
    )
  end

  # ───────────────────────────────────────────────────────────────────────────
  # What makes a verdict
  # ───────────────────────────────────────────────────────────────────────────

  test "a caller's own write to the wallet row counts as stale for the rest of its transaction" do
    Wallets::Wallet.stubs(:current_reads_need_locks?).returns(true)

    {
      "touch" => ->(wallet) { wallet.touch },
      "update!" => ->(wallet) { wallet.update!(metadata: {note: "seen"}) },
      "another copy's save" => ->(wallet) { Wallets::Wallet.find(wallet.id).update!(metadata: {note: "copy"}) }
    }.each do |write, perform|
      Wallets::Wallet.transaction do
        perform.call(@wallet)
        @wallet.lock!

        assert @wallet.send(:stale_snapshot?), "#{write} must leave the wallet stale"
      end
      assert_empty remembered_stale_snapshots, "#{write}: forgotten with its transaction"
    end
  end

  test "creating a wallet, the ledger's own writes and no-op saves never count as stale" do
    Wallets::Wallet.stubs(:current_reads_need_locks?).returns(true)

    Wallets::Wallet.transaction do
      fresh = create_wallet(@owner, asset_code: :created_here, initial_balance: 50)
      fresh.credit(10, category: :reward)
      fresh.hold(category: :chargeback)
      fresh.save!
      fresh.lock!

      refute fresh.send(:stale_snapshot?)
      assert_empty remembered_stale_snapshots
    end
  end

  test "own writes are ignored where plain reads are always current" do
    Wallets::Wallet.stubs(:current_reads_need_locks?).returns(false) # PostgreSQL, SQLite

    Wallets::Wallet.transaction do
      @wallet.touch
      assert_empty remembered_stale_snapshots
    end
  end

  private

  def connection
    Wallets::Wallet.connection
  end

  def at_end_of_real_transaction(&block)
    @wallet.send(:at_end_of_real_transaction, connection, &block)
  end

  def remembered_stale_snapshots
    ActiveSupport::IsolatedExecutionState[:wallets_stale_snapshots].to_a
  end
end
