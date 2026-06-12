# frozen_string_literal: true

require "test_helper"

class Wallets::EngineTest < ActiveSupport::TestCase
  test "gem code is not added to the host app autoloaders" do
    # Registering lib/wallets/models with Zeitwerk would claim top-level
    # constants like ::Wallet and ::Transaction, shadowing (and breaking)
    # host apps that define models with those very common names.
    gem_lib = Wallets::Engine.root.join("lib").to_s

    Rails.autoloaders.each do |autoloader|
      autoloader.dirs.each do |dir|
        refute dir.to_s.start_with?(gem_lib), "#{dir} must not be autoloaded from the wallets gem"
      end
    end
  end

  test "all gem constants are eagerly available without autoloading" do
    assert defined?(Wallets::Wallet)
    assert defined?(Wallets::Transaction)
    assert defined?(Wallets::Allocation)
    assert defined?(Wallets::Transfer)
    assert defined?(Wallets::HasWallets)
    assert defined?(Wallets::Embeddable)
    assert defined?(Wallets::HasMetadata)
  end

  test "active record models gain the has_wallets macro" do
    assert_respond_to ActiveRecord::Base, :has_wallets
    assert_respond_to User, :has_wallets
  end
end
