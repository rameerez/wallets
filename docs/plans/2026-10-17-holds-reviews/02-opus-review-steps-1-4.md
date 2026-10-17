# Adversarial review of steps 1–4 (Opus, 2026-10-17, at commit dc88b82)

## Blocking

None. Fixes F1 to F8 are all present at `dc88b82` and each has a test. The full suite passed in a scratch clone on SQLite, PostgreSQL and MySQL: 425 runs, 0 failures, 100 % line and 98.31 % branch coverage. standardrb is clean on `lib` and `test`.

## Should fix

1. **The stale verdict can outlive its real transaction.** This is an F1 gap. See `lib/wallets/models/wallet.rb:722-729` and `:747-754`.
   - **What the code does:** the verdict is keyed only by connection, table and id, and an after_commit or after_rollback hook removes it. If a commit hook registered ahead of it raises, Rails skips the hooks after it, so the key is never removed. A host model's `after_commit` raising is enough. On every later transaction `remember_stale_snapshot!` returns early, so nothing ever re-arms the cleanup.
   - **Verified on MySQL:** after one such commit, every later unrelated transaction on that thread's connection gets `stale_snapshot? == true` for that wallet. A plain `debit` in a new transaction then issues 3 locking ledger reads.
   - **What the plan requires:** "The stale verdict lives exactly as long as the real (outermost) database transaction, never a savepoint." The plan rejected always-locking reads because the gap locks deadlock unrelated wallets.
   - **Fix:** make a leaked entry harmless. Store the real transaction with the key, and treat an entry whose transaction is no longer `open?` as absent. Keep the hook only as cleanup.
   - **Test that would catch it:** register `ActiveRecord::Base.current_transaction.after_commit { raise }`, then `touch` the wallet. Rescue the commit error. Assert that the next transaction's `stale_snapshot?` is false and that nothing remains remembered.

2. **`hold_released` leaves out `category` and `amount`.** See `lib/wallets/models/wallet.rb:947-952`.
   - **What the code does:** releasing a reservation reports nil for both `context.amount` and `context.category`.
   - **What the plan requires:** §10 says "Context fields per event: `hold`, `wallet`, `amount` (reservations), `category`, …". The gem's own initializer template, at `lib/generators/wallets/templates/initializer.rb:83`, documents `ctx.category` as "the hold's on hold events".
   - **Fix:** pass `amount: hold.amount, category: hold.category`, the same way `dispatch_hold_created!` does.
   - **Test that would catch it:** release `reserve(30, category: :booking)`. Assert the amount is 30, the category is `"booking"`, and the exact set of context keys, as the `hold_created` test at `test/integration/wallet_callbacks_test.rb:370` does.

## Nits

- The comment at `lib/wallets/models/wallet.rb:1260-1263` overclaims. After a rolled-back command the wallet is clean, but it keeps the rolled-back `balance` and `updated_at` in memory until its next lock. Verified: `read_attribute(:balance)` showed 90 while the database held 100.
- `at_end_of_real_transaction` at `wallet.rb:747-754` hooks the internal, undocumented transaction object. Rails 7.2+ offers public `open?`, `after_commit` and `after_rollback` through `connection.current_transaction.user_transaction`.
- The test at `test/integration/wallet_callbacks_test.rb:569` passes only because the hold still holds the subclass instance that created it. Verified: `Wallets::Hold.find(id).release!` releases through `Wallets::Wallet` and fires `hold_released` even though the subclass maps that event to nil.
- `reserve` refuses bad amounts with `ArgumentError`, but §7 lists "amount" under `Wallets::InvalidHold`. The step 7 docs should say which errors are meant, probably the capture amount.
- The `:preserve` fallback decided by eligible remaining value, at `wallet.rb:524`, is step 5 work (§6.7) that shipped in the steps 1–3 commit. Its CHANGELOG entry is still owed.

## Missing tests

- §11 D6 asks that "incoming credit and release succeed" while available is negative with overdrafts off. Only the credit half is tested, at `test/models/wallets/wallet_holds_test.rb:462`. No `release!` runs in that state.
- No test checks `hold_released` for a reservation, with its `amount`, `category` and key set. This would have caught Should fix 2.
- No test checks that the stale verdict is gone after a real transaction whose commit hooks raise. This would have caught Should fix 1.

My probe tests are in `/private/tmp/claude-501/-Users-javi-GitHub-carhey/4a2503a2-284b-444a-8814-da3fd445d709/scratchpad/review-probes/`. I removed the scratch worktree afterwards. The main worktree and the `wallets_test` databases were not touched.

VERDICT: PASS
