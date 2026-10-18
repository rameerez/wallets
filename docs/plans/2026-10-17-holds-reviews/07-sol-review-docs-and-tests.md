# Review of the 0.4.0 documentation and test suite (Codex Sol, 2026-10-18, at the released ec479a9)

Scope: README, CHANGELOG, initializer template and the whole test suite (the parts no Codex review had covered). Verdict: BLOCK on two documentation contracts (the cached column stores the available balance, not the total; capture must check state before amount); fixes ship in 0.4.1 together with the test-harness improvements listed.

## Blocking

- **Upgrade advice recommends the wrong reconciliation balance.** [README.md:558](/Users/javi/GitHub/wallets-holds/README.md:558) says: “Screens and reports that mean ‘everything the user has’, such as a total earned or a reconciliation against the cached column, should read `total_balance`.” But [the cache writer](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:1640) uses `available = current_balance`, then `update!(balance: available, ...)`. Reserving 30 from 100 leaves cached balance 70 and total balance 100. Following this advice creates false reconciliation discrepancies.

- **Capture error precedence contradicts the documented retry contract.** [README.md:447](/Users/javi/GitHub/wallets-holds/README.md:447) promises: “The reservation’s state is checked before the amount, so retrying a finished capture always raises `Wallets::InvalidHold`.” CHANGELOG repeats this. However, [capture_reservation!](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:1254) calls `normalize_positive_amount!(amount)` before `ensure_capturable!(reservation)`. Calling `capture!(0, category: :purchase)` on an ended reservation raises `ArgumentError`, bypassing a retry handler rescuing `InvalidHold`.

## Should fix

- **Several concurrency tests do not exercise competing database transactions.** [transfer_test.rb:390](/Users/javi/GitHub/wallets-holds/test/models/wallets/transfer_test.rb:390) replaces `lock_wallet_pair!` with its own implementation and performs one transfer. The threaded tests at [wallet_test.rb:232](/Users/javi/GitHub/wallets-holds/test/models/wallets/wallet_test.rb:232) and [transfer_test.rb:623](/Users/javi/GitHub/wallets-holds/test/models/wallets/transfer_test.rb:623) retain transactional fixtures; Rails pins their shared connection, so `with_connection` does not provide independent transactions. Move these cases into the nontransactional concurrency harness and assert distinct connections.

- **The stale-read helper can hang instead of reporting a failure.** In [current_reads_test.rb:573](/Users/javi/GitHub/wallets-holds/test/integration/current_reads_test.rb:573), a worker exception before `read_taken << true` strands the main thread at `read_taken.pop`. An exception from `interleaved.call` strands the worker at `go_on.pop`, retaining its transaction and connection. Add bounded waits, exception propagation, and guaranteed worker cleanup.

- **The ledger-row promise needs qualification.** [README.md:53](/Users/javi/GitHub/wallets-holds/README.md:53) says: “Every balance change made through the wallet API creates a transaction row”. But [place_hold!](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:1179) changes available balance through `hold_class.create!` and `refresh_cached_balance!`, without creating a transaction. Explain that reconstructing available-balance changes also requires hold records.

## Nits

- [upgrade_generator_test.rb:45](/Users/javi/GitHub/wallets-holds/test/generators/upgrade_generator_test.rb:45) substitutes `Migration[7.2]` to simulate changed migration contents. On the Rails 7.2 matrix this changes nothing, so that part of the regression test passes without exercising its stated condition. Assert the contents actually changed.

## Missing tests

- Ended reservations × invalid capture amounts: captured, released, and lapsed states combined with zero, negative, fractional, and nonnumeric amounts. Existing tests check invalid amounts only while active and ended states with the amount omitted.
- Plan §11’s contention cases need guaranteed overlap. [all_at_once](/Users/javi/GitHub/wallets-holds/test/integration/current_reads_test.rb:615) queues start tokens before workers report readiness; one operation can finish before another obtains its connection. Add readiness barriers and forced contention, with deterministic coverage of both winner orders.

VERDICT: BLOCK