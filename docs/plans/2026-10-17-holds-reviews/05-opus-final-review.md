# Final review of the branch (Opus, 2026-10-18, at commit 3f1866f)

I reviewed HEAD 3f1866f. HEAD is blocked by one defect: on MySQL, held value can be spent. It is Astra's finding, I reproduced it on a real database, and its fix is already being written.

The brief said nobody was editing the worktree, but someone was. Uncommitted changes appeared in `lib/`, `test/` and the plan during the review, and they add a `ledger_revision` column. Every run below used a clean clone pinned to 3f1866f. Findings first read from the working copy were rechecked against the commit with `git show HEAD` and `git grep HEAD`.

**Test runs at HEAD**

- **wallets suite:** passes on SQLite, PostgreSQL and MySQL, under both Rails 8.1.3 and 7.2.4. Each run has 523 runs and 0 failures, with 100% line and 98.56% branch coverage.
- **standardrb** is clean, the RBS file parses (rbs 4.2.0), and the built gem contains the new template and generator.

**usage_credits against 0.4.0**

- **The pin blocks the test.** With `WALLETS_PATH` set, Bundler refuses: "every version of usage_credits depends on wallets ~> 0.3.0". The baseline on the published 0.3.0 passes: 838 runs, 2415 assertions, 0 failures.
- **Pin widened in a scratch copy only.** With `">= 0.3.0", "< 0.5"`, 832 pass and 6 error. All six are in `CoexistenceTest` with "Could not find table 'wallets_holds'". They come from the standalone `Wallets::Wallet` that its dummy app also runs. That is the designed loud failure (D11), not an embedding break.
- **With the holds migration added** to its dummy app, it passes 838 runs, 2415 assertions, 0 failures. Its own `UsageCredits::Wallet` needed no change. That covers its `current_balance` override and its calls to `apply_debit`, `refresh_cached_balance!`, `dispatch_balance_threshold_callbacks!`, `positive_remaining_balance` and `unbacked_negative_balance(scope)`.
- **What usage_credits needs:** widen the pin and add the holds migration to its coexistence dummy schema. Once the fix lands, that schema also needs `ledger_revision`, because the uncommitted code raises when a ledger that keeps holds lacks it.

## Blocking

1. **`lib/wallets/models/wallet.rb:761`: a stale MySQL snapshot is passed off as current.** This is Astra's finding.
   - **What the code does:** `stale_snapshot?` treats a match on `updated_at` and `balance` as proof the snapshot is current. Another connection can restore that pair with `touch(time: original)` after a change that moves no balance.
   - **Reproduced on MySQL:**
     - The credit already carries a fraud hold.
     - Connection A reads first. Connection B adds a second hold on the same credit, touches the wallet back to its old timestamp, and commits.
     - A releases the fraud hold and then runs `debit(50)`, which succeeds. 50 is allocated from a credit that an active hold still covers.
     - The cached balance reads 50 while the computed balance is 0.
   - **What the plan requires:** §6 says reads must "see current rows" and that every change writes "a strictly increasing `updated_at`". The plan's out-of-scope list names raw SQL and `update_columns`, not `touch(time:)`.
   - **Fix:** the `ledger_revision` counter now being written.
   - **Test that would catch it:** the probe below; adopt it as the regression test.

## Should fix

1. **`lib/wallets/models/hold.rb:53-65`: the capture link's content is never checked.**
   - **What the code does:** it validates the row's shape only.
   - **What the plan requires:** §4 says capture "verifies under lock that the linked transaction is a debit in the same wallet and that its absolute amount does not exceed the reservation amount".
   - **Fix:** a model validation for those three conditions. Plan §14 already schedules it.

2. **The deploy-order warning is missing from the README's upgrade section and the CHANGELOG.**
   - **What happens:** new code running before the migration makes every `Wallets::Wallet` creation and balance read raise `StatementInvalid`. The usage_credits errors above prove it.
   - **Fix:** say the migration must run before the new code serves traffic.

## Nits

- **Error order in `hold`** (`wallet.rb:444-445`). The deadline is checked before the target. So `hold(foreign_credit, until: 1.minute.ago)` raises `InvalidHold` while `hold(foreign_credit)` raises `ArgumentError`. §7 wants the wrong-argument error to win; swap the two lines.
- **Balance validation** (`wallet.rb:193`). `validates :balance` checks the computed `balance` method, not the column. One debit therefore runs the full balance statement three times, and `create!` needs the holds table. Validate `read_attribute(:balance)` instead.
- **Wallet callbacks** (`wallet.rb:1605`). Commands that leave the cached balance unchanged write with `update_column`, so the host's `after_save` and `after_commit` on the wallet do not run. A held credit fired 0 saves, where 0.3's `save!` ran them on every command.
- **CHANGELOG test counts are stale** (line 39). HEAD has 523 runs, 2466 assertions and 30 SQLite skips, against 521, 2447 and 29.
- **README:544 and README:644** say success callbacks run after the outermost commit. Under `transaction(joinable: false)` they fire earlier. This is Astra's point and is already scheduled.
- **Trilogy detection** (`add_wallets_holds.rb.erb:113`). It matches only `"mysql"`, and so does the 0.1 install template. I did not run Trilogy.
- **RBS** omits `Configuration#on_hold_created` and `#on_hold_released`, `CallbackContext#hold`, and `WalletBase.hold_class_name`.

## Missing tests

- **MySQL:** another connection restores the marker with `touch(time:)` after a balance-neutral hold. The stale reader's release and debit must be refused.
- **§11 shape and links:** a capture link to another wallet's debit, to a credit, and to a debit larger than the reservation must each be rejected.

VERDICT: BLOCK

0.4.0 is not safe to publish at 3f1866f. Held value can be spent on MySQL through a public Active Record call, as reproduced above. The rest of the branch reads correctly against the plan and passes the full matrix on both Rails versions. It becomes safe once three things land and pass the full matrix on real MySQL and PostgreSQL: the `ledger_revision` fix with the regression above, the capture-link validation, and a re-review. The uncommitted fix has a weaker path for tables without the column, such as usage_credits on MySQL. When the balance does not move, it calls a plain `touch`, which writes nothing under `no_touching` and can repeat under a frozen clock. HEAD's `update_column` marker did neither, so keep that in the fallback. Beyond the CHANGELOG, the release notes must warn about four things:

- **Run the migration before the new code serves traffic.** Without it, every `Wallets::Wallet` creation and balance read raises.
- **Apps that use both gems stay on 0.3.** That lasts until usage_credits widens its pin. Then their standalone tables need the migration, including `ledger_revision`.
- **MySQL correctness depends on the wallet API.** Every change must go through it: no raw SQL to wallet rows, and no direct writes, edits or destroys of hold rows.
- **Callbacks can fire before the real commit** inside `transaction(joinable: false)`.

The probes are in `/private/tmp/claude-501/-Users-javi-GitHub-carhey/4a2503a2-284b-444a-8814-da3fd445d709/scratchpad/final-probes/`. The MySQL reproduction is `touch_probe.rb`, appended to `test/integration/current_reads_test.rb` and run with `-n /probe/`. Both scratch worktrees were removed afterwards. The usage_credits repo is clean, and nothing ran in `/Users/javi/GitHub/wallets-holds` or against the `wallets_test` databases.
