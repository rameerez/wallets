# frozen_string_literal: true

require "test_helper"

class WalletsTest < ActiveSupport::TestCase
  test "VERSION is a semantic version string" do
    assert_match(/\A\d+\.\d+\.\d+\z/, Wallets::VERSION)
  end

  test "configuration is memoized until reset" do
    config = Wallets.configuration

    assert_same config, Wallets.configuration

    Wallets.reset!

    refute_same config, Wallets.configuration
  end

  test "configure yields the active configuration" do
    yielded = nil
    Wallets.configure { |config| yielded = config }

    assert_same Wallets.configuration, yielded
  end

  test "a replacement configuration can be assigned directly" do
    custom = Wallets::Configuration.new
    Wallets.configuration = custom

    assert_same custom, Wallets.configuration
  ensure
    Wallets.reset!
  end

  test "normalize_asset_code is the single source of truth for asset naming" do
    assert_equal "eur", Wallets.normalize_asset_code(" EUR ")
    assert_equal "wood", Wallets.normalize_asset_code(:WOOD)
    assert_equal "", Wallets.normalize_asset_code(nil)
  end

  test "error hierarchy lets apps rescue all gem errors at once" do
    assert_operator Wallets::InsufficientBalance, :<, Wallets::Error
    assert_operator Wallets::InvalidTransfer, :<, Wallets::Error
    assert_operator Wallets::Error, :<, StandardError
  end
end
