# Review of 0.4.1 (Codex Sol, 2026-10-18, at commit 53c5b73, PR #7)

Scope: the 0.4.1 candidate in full (`git diff ec479a9..53c5b73`: README stories and corrections, the `capture!` fix, the concurrency-harness rework), read-only. Verdict: PASS; both should-fix items and the nit were applied in the next commit (the game and loyalty snippets read `held_balance`, the vesting examples are declared independent, `all_at_once` fails at once when the pool is too small for the race, the reasons snippet orders its holds).

## Blocking

None. Both prior blockers are fixed and covered: cached reconciliation uses `wallet.balance`, and capture checks state before amount. The CHANGELOG “Fixed” entry accurately describes the implementation.

## Should fix

- **README examples assume fresh wallets without saying so.** The [game story](README.md:833) follows a 500-gem purchase: continuing that example produces **500 available / 1500 total**, then **1500 available** after release. Its test starts empty. The [vesting examples](README.md:1238) likewise reuse `points`, while their tests independently reset the wallet. State explicitly that these are independent examples, or preserve prior balances in the comments and tests.

- **The readiness barrier requires at least three pooled connections.** The [opposing-transfer test](test/integration/current_reads_test.rb:381) always starts two racers while the main thread retains its connection. With `RAILS_MAX_THREADS=2`, one racer holds the only free connection awaiting the start signal, preventing the other from reporting readiness. Configure or enforce the minimum pool size; the default five works.

## Nits

- The [retention example](README.md:1308) promises an ordered category array without ordering the association. Its [test](test/integration/readme_use_cases_test.rb:387) adds `.sort`, masking that discrepancy. Add `.sort` to the README expression too.

## Missing tests

- **Guaranteed contention and both winner orders remain uncovered.** [all_at_once](test/integration/current_reads_test.rb:770) guarantees distinct checked-out connections before releasing workers, but one command can still finish before another executes. The [hold/debit test](test/integration/current_reads_test.rb:416) accepts whichever outcome occurs across eight repetitions without requiring both. Add controlled lock contention and deterministic coverage of each winner; the CHANGELOG’s claim that these tests now race is stronger than the guarantee.

VERDICT: PASS

Based on the read-only code review, 0.4.1 is safe to publish, with the nonblocking documentation and test limitations above.
## Disposition (lead)

Applied in the next commit: both should-fix items and the nit. On the missing tests: both winner orders of a hold racing a debit were already deterministic ("hold refuses a credit that a debit committed after its caller's first read spent" and "a debit never spends a credit that a hold committed after its caller's first read covers"); the two orders of a capture racing a release now are too, through the same stale-read helper. Forcing lock contention inside `all_at_once` is not attempted: the barrier guarantees a connection per racer before any starts, and the row locks are observed from the actual `FOR UPDATE` statements.
