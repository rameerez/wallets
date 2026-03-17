# frozen_string_literal: true

require "simplecov"

ENV["RAILS_ENV"] = "test"

require File.expand_path("dummy/config/environment.rb", __dir__)
ActiveRecord::Migrator.migrations_paths = [
  File.expand_path("dummy/db/migrate", __dir__),
  File.expand_path("../db/migrate", __dir__)
]
require "rails/test_help"
require "minitest/mock"
require "mocha/minitest"

Minitest.backtrace_filter = Minitest::BacktraceFilter.new

if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths << File.expand_path("fixtures", __dir__)
  ActionDispatch::IntegrationTest.fixture_paths << File.expand_path("fixtures", __dir__)
elsif ActiveSupport::TestCase.respond_to?(:fixture_path=)
  ActiveSupport::TestCase.fixture_path = File.expand_path("fixtures", __dir__)
  ActionDispatch::IntegrationTest.fixture_path = ActiveSupport::TestCase.fixture_path
end

ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures/files", __dir__)
ActiveSupport::TestCase.fixtures :all

class ActiveSupport::TestCase
  setup do
    Wallets.reset!
    Wallets.configure do |config|
      config.default_asset = :coins
      config.additional_categories = %w[
        quest_reward
        marketplace_sale
        ride_fare
        peer_payment
      ]
    end
  end

  teardown do
    Wallets.reset!
  end

  def create_wallet(owner, asset_code: nil, initial_balance: 0)
    Wallets::Wallet.create_for_owner!(
      owner: owner,
      asset_code: asset_code || Wallets.configuration.default_asset,
      initial_balance: initial_balance
    )
  end
end
