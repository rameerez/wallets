# frozen_string_literal: true

require "simplecov"
SimpleCov.start

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

  # Hold rows written straight to the table: a credit hold when given a
  # credit, else a wallet hold. They pin the model and the balance math
  # beneath the commands, and build rows the commands cannot (a capture link).
  # Code under test creates holds with `hold`, `reserve` and `credit(hold:)`.
  def hold!(wallet, credit = nil, category: :review, **attributes)
    Wallets::Hold.create!(wallet: wallet, credit: credit, category: category, **attributes)
  end

  def reservation!(wallet, amount, category: :booking, **attributes)
    Wallets::Hold.create!(wallet: wallet, amount: amount, category: category, **attributes)
  end

  # Every SQL statement the block runs, schema and transaction noise aside.
  def capture_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
