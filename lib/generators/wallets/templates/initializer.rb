# frozen_string_literal: true

Wallets.configure do |config|
  # The asset returned by owner.wallet with no argument.
  # Common examples:
  # - :credits for usage-based apps
  # - :coins or :gems for games
  # - :eur or :usd for marketplace balances
  # - :wood for resource-based economies
  config.default_asset = :credits

  # Prefix for the generated tables.
  #
  # Set this BEFORE running rails db:migrate for the first time.
  # Treat it as permanent once the wallet tables exist.
  #
  # config.table_prefix = "wallets_"

  # Set to true only if your domain explicitly supports debt or overdrafts.
  #
  # config.allow_negative_balance = false

  # Optional threshold that fires on_low_balance_reached when crossed.
  # Set to nil to disable.
  #
  # config.low_balance_threshold = 100

  # Extra business event labels so the ledger stays readable.
  # These extend the built-in defaults:
  # :credit, :debit, :transfer, :expiration, :adjustment
  #
  # config.additional_categories = %w[
  #   ride_fare
  #   seller_payout
  #   reward_redemption
  #   marketplace_sale
  #   quest_reward
  #   resource_gathered
  # ]
  #
  #
  # === Lifecycle Callbacks ===
  #
  # Hook into wallet events for analytics, notifications, and custom logic.
  # All callbacks receive a context object with event-specific data.
  #
  # Available callbacks:
  #   on_balance_credited      - After value is added to a wallet
  #   on_balance_debited       - After value is deducted from a wallet
  #   on_transfer_completed    - After a transfer between wallets succeeds
  #   on_low_balance_reached   - When balance drops below the threshold
  #   on_balance_depleted      - When balance reaches exactly zero
  #   on_insufficient_balance  - When a debit or transfer is rejected
  #
  # Context object properties (available depending on event):
  #   ctx.event            # Symbol - the event name
  #   ctx.owner            # The wallet owner (User, Team, Guild, etc.)
  #   ctx.wallet           # The Wallets::Wallet instance
  #   ctx.amount           # Balance involved
  #   ctx.previous_balance # Balance before the operation
  #   ctx.new_balance      # Balance after the operation
  #   ctx.transaction      # The Wallets::Transaction record
  #   ctx.transfer         # The Wallets::Transfer record
  #   ctx.category         # Transaction category
  #   ctx.threshold        # Low balance threshold
  #   ctx.metadata         # Additional event-specific context
  #   ctx.to_h             # Hash representation without nil values
  #
  # IMPORTANT: Keep callbacks fast. Use background jobs for email,
  # analytics, or anything that should not block balance operations.
  #
  # config.on_balance_credited do |ctx|
  #   Rails.logger.info "[Wallets] Credited #{ctx.amount} to #{ctx.owner.class}##{ctx.owner.id}"
  # end
  #
  # config.on_balance_debited do |ctx|
  #   Rails.logger.info "[Wallets] Debited #{ctx.amount} from #{ctx.owner.class}##{ctx.owner.id}"
  # end
  #
  # config.on_transfer_completed do |ctx|
  #   Rails.logger.info "[Wallets] Transfer #{ctx.transfer.id} completed"
  # end
  #
  # config.on_insufficient_balance do |ctx|
  #   Rails.logger.info "[Wallets] #{ctx.owner.class}##{ctx.owner.id} needs #{ctx.amount}, has #{ctx.metadata[:available]}"
  # end
end
