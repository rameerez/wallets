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
end
