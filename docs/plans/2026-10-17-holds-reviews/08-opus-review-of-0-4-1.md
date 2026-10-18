# Review of 0.4.1 (Claude Opus 5.5, 2026-10-18, at commit 53c5b73, PR #7)

Scope: the whole 0.4.1 candidate (README stories, the two documentation corrections, the `capture!` state-before-amount fix, the concurrency-harness rework), run in a scratch worktree on Ruby 3.2.2 and 3.4.7 against SQLite, PostgreSQL and MySQL. Verdict: PASS; the should-fix items were applied in the next commit (README numbers that hold in context, the confirmed review ends the account hold, racers spawned one at a time with a fail-fast `ready`, a pool-size check, the two deterministic capture/release orders, the CHANGELOG wording).

## Blocking

None. Both previous blockers are fixed and pinned by tests.

- **Reconciliation advice.** README.md:559 now reconciles the cached column with `wallet.balance`. ReadmeHoldsTest pins 70 in the column, 70 available, 100 total, and the column staying at 70 after a lapse.
- **Capture order.** `capture_reservation!` now parses the amount in `capture_amount` after `ensure_capturable!`, inside `ending_hold`'s savepoint. The new test crosses 3 ended states with 6 bad amounts under `assert_nothing_written`. I also confirmed that retrying with an unknown category raises `InvalidHold`. The CHANGELOG "Fixed" entry is exact.

## Should fix

1. **The harness flakes on Ruby below 3.3.5 with the pinned Rails 8.1.3.1.** 3 of 40 runs on Ruby 3.2.2 errored in `all_at_once`'s `with_connection` (current_reads_test.rb:758). The error was `RuntimeError: can't add a new key into hash during iteration`. The cause is Rails 8.1.3.1's fallback `WeakThreadKeyMap#[]=`, which runs `select!` while other racers insert. Rails 8.1.4 fixed it with `Concurrent::Map`, and Ruby 3.3.5+ uses `ObjectSpace::WeakKeyMap`. On Ruby 3.4.7, Rails 8.1 ran 50 of 50 clean and Rails 7.2.4 ran 24 of 24 clean. CI is safe because its PostgreSQL and MySQL jobs run only Ruby 3.4, but the gemspec allows 3.2. The pattern predates this PR, which adds about 10 more `all_at_once` calls per run. Fix it by bumping Gemfile.lock to Rails 8.1.4, or by starting racers one at a time (spawn, await its `ready`, then the next), which keeps the barrier.
2. **`all_at_once` does not fail fast when a racer dies before reporting ready.** Nothing closes `ready`, so `await` waits the full 10-second PATIENCE before `join(0)` raises. The three failing runs each took 10 to 12 s longer. The `await` comment says "a sender that fails closes its queue on the way out", which is true only of `after_a_stale_read`. The CHANGELOG line "three harness tests prove a failing race fails fast" overstates it, since only the stale-read test proves that. Either poll in short slices and stop once a `from` thread is dead, or reword.
3. **Three README stories show numbers that hold only on an empty wallet**, though the surrounding code has already given that same variable value. I measured them in README order:
   - Game prize, README.md:833: the snippet above credits this `player` 500 gems. The real values are 500 available and 1500 total, then 1500 after release. The README says 0, 1000 and 1000.
   - Loyalty, README.md:1055: the section above credits `user.wallet(:points)` many times. With 150 earlier points the values are 150 available and 192 total, then 150 total after the return. The README says 0, 42 and 0.
   - Vesting, README.md:1233 and 1249: both snippets reuse `points` from the first one, which ends at 500 available. The creator snippet really gives 500 available and 1200 held, then 1300 and 400 two months on. The bonus snippet then gives 1300 available and 2700 total. The README says 0/1200, 800/400 and 0/1000.
   ReadmeUseCasesTest passes only because every test starts from a fresh wallet. Start each snippet from a new wallet, or comment on `held_balance` and the change.
4. **The confirmed review leaves the account hold in force.** At README.md:1319, after the `from:` transfer, `account_review.active?` is still true and both fraud_review holds stay active. That matches the README's own rule "The holds stay where they are". Still, `wallet.on_hold?` stays true and every later credit arrives held. The sentence at README.md:1264, "Every retention then ends one of two ways", reads as if `from:` ends the hold. Add `account_review.release!` to the confirmed branch and say that `from:` leaves hold rows in place.

## Nits

- **Unordered association.** README.md:1308 promises an order, but `Transaction has_many :holds` has no `order` (transaction.rb:187). The test sorts its result. Add `.order(:id)` to the snippet.
- **Lucia's payout.** README.md:924 says "the marketplace pays Lucia as above". That snippet pays 4500 out of a 5000 total, more than the 3750 captured.
- **CHANGELOG Tests omission.** It does not mention that the upgrade generator test now edits the migration with a sentinel line.
- **Pool size.** The default pool of 5 is fine. With `RAILS_MAX_THREADS=1`, "every racer holds a connection" pops an empty queue with no timeout and hangs.

## Missing tests

- **Deterministic winner orders for capture and release.** "A capture and a release racing" relies on 8 random races and checks whichever branch happens. No `after_a_stale_read` test has a capture find the reservation already released, or a release find it already captured.
- **Overlap in the new races.** The new debit and transfer races pass whether or not the racers actually overlapped, so they prove serialization only probabilistically.

VERDICT: PASS

0.4.1 is safe to publish: the one code change is correct and fully tested, and every open item is docs or test-only. Items 3 and 4 are small README edits worth landing first.

How I ran it: a scratch worktree, Ruby 3.2.2 and 3.4.7. The full suite gives 561 runs and 0 failures on SQLite, PostgreSQL and MySQL, matching the CHANGELOG. The local mysql2 builds link a missing /opt/homebrew/opt/mysql path, so I used a dyld fallback and a scratch bundle; that is an environment issue, not the PR. Both scratch worktrees are removed and the reviewed worktree is unchanged.

## Disposition (lead)

Applied in the next commit: 1 (racers spawned one at a time; the committed lock is already Rails 8.1.4), 2 (a racer that fails before it is ready closes `ready`, and a harness test proves the race fails at once), 3 (the game and loyalty snippets read `held_balance`, whose numbers hold whatever the wallet already has; the vesting section says its three examples are independent), 4 (the confirmed branch releases the account hold, and the prose says `from:` leaves hold rows in place), all four nits, and the two deterministic capture/release orders. Not applied: proving overlap in the serialization races, which would need lock contention the harness cannot force deterministically; the races keep their barrier and the row locks are observed from the actual statements.
