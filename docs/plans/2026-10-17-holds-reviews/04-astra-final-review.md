# Final review of the branch before merge (Codex Astra, 2026-10-18, at commit 3f1866f)

Scope: `lib` and `sig` (the README and CHANGELOG were cross-checked against the code separately). Verdict: BLOCK on the `updated_at` marker (fixed by replacing it with a `ledger_revision` counter), plus the Trilogy adapter detection in the migration templates and a capture-link content validation.

## Blocking

- **MySQL can mistake a stale snapshot for a current one after another connection touches the wallet.** [wallet.rb:760](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:760) returns false when `[updated_at, balance]` matches. However, `touch(time: old_timestamp)` can restore that exact pair; `remember_own_write` protects only the touching connection’s transaction.

  Concrete sequence: A establishes a repeatable-read snapshot of 100 credits covered by hold H1. B adds H2, then touches the wallet back to its original timestamp and commits; available remains zero. A releases H1. The marker matches, so A uses plain reads, misses H2, and calculates 100 available. An ordinary debit in that same transaction can then consume the still-held credit.

  §6 requires accounting reads to “**see current rows**” and relies on “**strictly increasing `updated_at`**.” Supported Rails touches can defeat that invariant without raw SQL.

  **Fix:** preserve a strictly increasing marker under the wallet lock for all supported saves/touches, including explicit timestamps, or compare a protected ledger revision instead. **Test:** reproduce this two-connection MySQL sequence; assert releasing H1 leaves zero available and the subsequent debit is rejected. Also cover ordinary `touch` under a frozen clock.

## Should fix

- [add_wallets_holds.rb.erb:113](/Users/javi/GitHub/wallets-holds/lib/generators/wallets/templates/add_wallets_holds.rb.erb:113) recognizes only `"mysql"` when suppressing JSON defaults. Rails’ Trilogy adapter identifies itself as `"Trilogy"`, so the upgrade emits literal JSON defaults, which MySQL rejects. Use the same `/mysql|trilogy/i` detection as the accounting code; align the install template and dummy migration. Add a real Trilogy migration test. [MySQL default-value rules](https://dev.mysql.com/doc/refman/8.0/en/data-type-defaults.html)

## Nits

None.

## Missing tests

- §11 concurrency: another connection restores the wallet timestamp after a balance-neutral ledger mutation; existing own-write tests cover only the stale reader’s own writes.
- §11 shape/link cases: explicit foreign-wallet and credit capture-link rejection cases are absent.
- Adapter portability: install/upgrade through Trilogy; current MySQL CI uses mysql2.

VERDICT: BLOCK

I would not publish 0.4.0 for a production money ledger until the marker defect is fixed and the regression passes on real MySQL. This was a read-only review; tests were not run. Beyond the CHANGELOG, release notes should explicitly require microsecond wallet timestamps—the upgrade does not enforce their precision—and explain that `joinable: false` boundaries can deliver success callbacks before the real outer transaction commits.