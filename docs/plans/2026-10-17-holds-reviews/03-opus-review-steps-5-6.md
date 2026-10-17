# Adversarial review of steps 5–6 (Opus, 2026-10-17, at commit a0ff06a)

## Blocking

None found. At HEAD a0ff06a the full suite passes on SQLite, PostgreSQL and MySQL against the `wallets_review` databases. Each run was 504 tests with 0 failures, at 100% line and 98.56% branch coverage. standardrb is clean.

I checked the rules the brief singled out, by reading the code and with probes in the scratch clone:
- **Targeted debits:**
  - The funding check in `named_buckets!` is the plan's D8 inequality.
  - `post_debit!` refuses any shortfall for `from:` whatever the overdraft flag.
  - The amount checked and the amount allocated come from the same locked rows, so a targeted debit is never left unbacked.
- **Capture:**
  - With overdrafts off, `available_for_capture` can never exceed the eligible credits, so a capture never leaves debt.
  - With overdrafts on, available balance never falls.
  - Snapshots and callbacks use only the original and final balances.
- **Stale-verdict fix:** Rails 7.2.4 and 8.1 both mark the real transaction finalized before its commit or rollback hooks run, and both keep it as `@stack.first`, so the fix rests on true facts.
- **Race tests:** the capture-versus-release test really exercises both orderings. Over 16 runs capture won 10 and release 6 on PostgreSQL, and 7 and 9 on MySQL.

## Should fix

1. **`wallet.rb:1182-1191` (`ending_hold`): on MySQL the reload after a failure throws away the fresh hold values and keeps stale ones.**
   - **What the code does:** `capture_reservation!` reads the reservation with `reservation.lock!` at `:1213`, which on MySQL always returns the current row. When the capture is then refused, `ending_hold` calls a plain `hold.reload`. Under MySQL repeatable read, inside a caller transaction that read before calling, that reload answers from the old snapshot and overwrites the current values.
   - **Reproduced on MySQL:** the caller reads the reservation, another connection captures it, then the caller's own capture fails with "was already captured (transaction 18)". Afterwards the caller's copy reads `captured? = false`, `active? = true`, `release_reason = nil`. A locking read in the same transaction reads `captured? = true`.
   - **What the plan and the code comment require:** the plan (§6.5) says *"apps reconcile through `capture_transaction`"*, and on this copy it reads nil. The comment above `ending_hold` says *"the caller's copy of the hold is read back from the ledger"*.
   - **Fix:** reload only when the failed block had already written the hold, since otherwise `lock!` has left the copy current. When it does reload, use a locking read on MySQL: `hold.reload(lock: self.class.current_reads_need_locks?)`.
   - **Test that would catch it:** in `CurrentReadsTest`, use `after_a_stale_read` with an interleaved capture. Rescue the `InvalidHold` and assert that the copy reports the capture, with `capture_transaction_id` equal to the winning debit's id.

2. **`wallet.rb:1106-1109` against `:1076-1080` and `:1280`: the same refusal raises different error classes, and the agreed error list was edited without a note.**
   - **Inside `from:` itself:** a named credit with nothing left raises `Wallets::InsufficientBalance`. A named credit that expired raises `ArgumentError`, so the error class flips on a clock tick for a credit that was valid when the caller looked it up.
   - **Against `hold`:** `wallet.hold(expired_credit)` and a credit from another wallet raise `Wallets::InvalidHold`, with the same message `from:` uses under `ArgumentError`.
   - **What the plan says (§6.6):** *"`amount ≤ Σ unexpired remaining of the sources`, else `Wallets::InsufficientBalance`"*.
   - **The silent edit:** this commit rewrites the plan's signed-off §7 error list (`docs/plans/2026-10-17-holds-and-reservations.md:210`). It changes *"`Wallets::InvalidHold` (target, amount, deadline, state) … `ArgumentError` for conflicting keywords"* so that the capture amount moves to `ArgumentError`, with no dated note. The step-3 change and the review-finding change in §6 each carry one.
   - **The gap left:** the edited list still names no error for refused `from:` sources.
   - **Fix:** raise `InsufficientBalance` for an expired source, as for a spent one. Keep `ArgumentError` for the wrong class, duplicates, another wallet's credit, or a debit. Record the §7 change as a dated implementation decision that lists the `from:` errors.

## Nits

- A targeted transfer reads and locks the named credits twice, at `wallet.rb:536` and again at `wallet.rb:908`. Passing the first result through would save a query.
- `covered_consumed:` in the `insufficient_balance` metadata (`wallet.rb:1079` and `:1086`) becomes public callback data that the plan does not list.
- `from:` accepts any relation through `Array.wrap` (`wallet.rb:1039`). An unordered relation spends credits in database order, but the plan says "an ordered array".

## Missing tests

- On MySQL, a capture refused as already captured after a stale read should leave the caller's copy showing the winning capture. This goes with Should fix 1.
- Every other §11 case owed by steps 5 and 6 is present.

The scratch clone is at /private/tmp/claude-501/-Users-javi-GitHub-carhey/4a2503a2-284b-444a-8814-da3fd445d709/scratchpad/review-clone-56. The probes are in its test/review folder and are not committed.

VERDICT: PASS
