# frozen_string_literal: true

Wallets.configure do |config|
  config.default_asset = :coins
  config.additional_categories = %w[
    quest_reward
    marketplace_sale
    ride_fare
    peer_payment
  ]
end
