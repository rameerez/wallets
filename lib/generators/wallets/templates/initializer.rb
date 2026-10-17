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
  # Applies consistently to `debit`, `transfer_to`, `reserve` and `capture!`:
  # each may then go beyond the available balance. Cap how negative a
  # wallet can go in your own service layer (the flag is binary).
  #
  # The flag decides what commands may do, not what the balance may read.
  # With it off, the available balance can still go negative when a hold
  # covers value that is also reserved, or when reserved value expires.
  # Such wallets stay saveable: they take credits and releases, and refuse
  # new spending, so turning the flag off is safe at any time.
  #
  # config.allow_negative_balance = false

  # Optional threshold that fires on_low_balance_reached when crossed.
  # Set to nil to disable.
  #
  # config.low_balance_threshold = 100

  # Extra business event labels so the ledger stays readable.
  # These extend the built-in defaults:
  # :credit, :debit, :transfer_in, :transfer_out, :refund,
  # :reward, :purchase, :top_up, :adjustment
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
  #   on_low_balance_reached   - When the available balance drops to the
  #                              threshold or below (one-shot per crossing)
  #   on_balance_depleted      - When the available balance drops from
  #                              positive to zero or below: a debit, a hold
  #                              or a reservation (one-shot per crossing)
  #   on_insufficient_balance  - When a debit, transfer, reservation or
  #                              capture is refused for lack of funds
  #   on_hold_created          - After a hold or a reservation is placed
  #   on_hold_released         - After hold.release! or capture! ends a hold
  #                              (a deadline passing is computed, never
  #                              announced)
  #
  # Balances work like a bank statement: wallet.balance is the AVAILABLE
  # balance (what can be spent now), wallet.held_balance is what holds and
  # reservations keep pending, and wallet.total_balance is both together.
  # previous_balance and new_balance always report the available balance.
  #
  # Context object properties (available depending on event):
  #   ctx.event            # Symbol - the event name
  #   ctx.owner            # The wallet owner (User, Team, Guild, etc.)
  #   ctx.wallet           # The Wallets::Wallet instance
  #   ctx.amount           # Amount involved (a reservation's, on hold events)
  #   ctx.previous_balance # Available balance before the operation
  #   ctx.new_balance      # Available balance after the operation
  #   ctx.transaction      # The Wallets::Transaction record (a capture's debit
  #                        # on hold_released)
  #   ctx.transfer         # The Wallets::Transfer record
  #   ctx.hold             # The Wallets::Hold record (hold events)
  #   ctx.category         # Transaction category (the hold's on hold events)
  #   ctx.threshold        # Low balance threshold
  #   ctx.metadata         # Additional event-specific context (a hold's
  #                        # creation metadata, or its release metadata)
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
  #
  # config.on_hold_created do |ctx|
  #   Rails.logger.info "[Wallets] #{ctx.category} hold on #{ctx.owner.class}##{ctx.owner.id}, available #{ctx.new_balance}"
  # end
  #
  # on_hold_released carries the hold's category, its amount (reservations
  # only) and the release metadata. On a capture, ctx.transaction is the
  # debit the capture posted, which carries the capture's metadata.
  #
  # config.on_hold_released do |ctx|
  #   if ctx.transaction
  #     Rails.logger.info "[Wallets] #{ctx.category} reservation captured as transaction #{ctx.transaction.id}"
  #   else
  #     Rails.logger.info "[Wallets] #{ctx.category} hold released: #{ctx.hold.release_reason}"
  #   end
  # end
end
