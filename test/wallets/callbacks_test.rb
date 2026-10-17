# frozen_string_literal: true

require "test_helper"

class Wallets::CallbacksTest < ActiveSupport::TestCase
  test "dispatch ignores missing callbacks" do
    Wallets::Callbacks.dispatch(:balance_depleted, wallet: wallets_wallets(:rich_coins_wallet))

    assert_nil Wallets.configuration.on_balance_depleted_callback
  end

  test "dispatch supports zero arity callbacks" do
    called = false

    Wallets.configure do |config|
      config.on_balance_depleted { called = true }
    end

    Wallets::Callbacks.dispatch(:balance_depleted, wallet: wallets_wallets(:rich_coins_wallet))

    assert called
  end

  test "dispatch warns on unexpected callback arity" do
    Wallets.configure do |config|
      config.on_balance_credited { |_ctx, _extra| nil }
    end

    Wallets::Callbacks.expects(:log_warn).with { |message| message.match?(/unexpected arity/) }

    Wallets::Callbacks.dispatch(:balance_credited, wallet: wallets_wallets(:rich_coins_wallet))
  end

  test "dispatch logs callback errors without raising" do
    Wallets.configure do |config|
      config.on_balance_debited { |_ctx| raise "boom" }
    end

    Wallets::Callbacks.expects(:log_error).with { |message| message.match?(/Callback error/) }
    Wallets::Callbacks.expects(:log_debug)

    Wallets::Callbacks.dispatch(:balance_debited, wallet: wallets_wallets(:rich_coins_wallet))
  end

  test "dispatch ignores unknown events instead of raising" do
    assert_nothing_raised do
      Wallets::Callbacks.dispatch(:made_up_event, wallet: wallets_wallets(:rich_coins_wallet))
    end
  end

  test "dispatch supports callbacks with splat arguments" do
    captured = []
    Wallets.configure do |config|
      config.on_balance_depleted { |*args| captured.concat(args) }
    end

    Wallets::Callbacks.dispatch(:balance_depleted, wallet: wallets_wallets(:rich_coins_wallet))

    assert_equal 1, captured.size
    assert_instance_of Wallets::CallbackContext, captured.first
  end

  test "a raising callback never breaks the ledger write" do
    Wallets.configure do |config|
      config.on_balance_credited { |_ctx| raise "callback exploded" }
    end

    wallet = wallets_wallets(:rich_coins_wallet)
    transaction = nil

    assert_difference -> { wallet.transactions.count }, 1 do
      transaction = wallet.credit(25, category: :reward)
    end

    assert transaction.persisted?
    assert_equal 1025, wallet.reload.balance
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Logging plumbing
  # ───────────────────────────────────────────────────────────────────────────

  test "log_error and log_warn prefer the Rails logger" do
    fake_logger = mock
    fake_logger.expects(:error).with("boom")
    fake_logger.expects(:warn).with("careful")
    Rails.stubs(:logger).returns(fake_logger)

    Wallets::Callbacks.log_error("boom")
    Wallets::Callbacks.log_warn("careful")
  end

  test "log_error and log_warn fall back to Kernel#warn without a Rails logger" do
    Rails.stubs(:logger).returns(nil)

    assert_output(nil, /boom\ncareful/) do
      Wallets::Callbacks.log_error("boom")
      Wallets::Callbacks.log_warn("careful")
    end
  end

  test "log_debug logs only when the logger is at debug level" do
    chatty = mock
    chatty.stubs(:debug?).returns(true)
    chatty.expects(:debug).with("details")
    Rails.stubs(:logger).returns(chatty)

    Wallets::Callbacks.log_debug("details")

    quiet = mock
    quiet.stubs(:debug?).returns(false)
    quiet.expects(:debug).never
    Rails.stubs(:logger).returns(quiet)

    Wallets::Callbacks.log_debug("details")

    Rails.stubs(:logger).returns(nil)

    assert_nothing_raised { Wallets::Callbacks.log_debug("details") }
  end
end
