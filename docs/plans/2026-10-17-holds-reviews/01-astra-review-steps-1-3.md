# Adversarial review of steps 1–3 (Codex Astra, 2026-10-17, at commit aeca0e6)

Prompt: the review template with the step-specific focus (see `../2026-10-17-holds-negotiation/` for the plan negotiation). Verdict: BLOCK, eight findings, all fixed in `dc88b82` and recorded in the plan (§6, §9, §14).

## Blocking

1. **[wallet.rb:599](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:599) — The stale memo can expire before the database transaction.**  
   `transaction.after_commit { stale_snapshots.delete(key) }` runs when a savepoint beneath `transaction(joinable: false)` commits. I reproduced the memo disappearing while the outer transaction remained open. After the first command writes the wallet, a second command sees matching wallet rows and incorrectly uses stale accounting reads. §6 requires the verdict to be “remembered until commit or rollback.” Track the physical outer transaction’s lifetime. Test the existing two-debit stale scenario beneath a nonjoinable outer transaction; allocations must never exceed the credit.

2. **[wallet.rb:595](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:595) — Matching wallet rows do not prove a fresh snapshot.**  
   Code returns false when `snapshot == [updated_at, read_attribute(:balance)]`. Sequence: T1 reads a 100 balance; T2 debits 60 and commits; T1 calls `wallet.touch`, then debits 60. Its own wallet update becomes visible, while the allocation snapshot remains stale; the detector says fresh and permits over-allocation. This follows [MySQL’s documented visibility of own writes](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html). §6 requires accounting reads to “see current rows.” Use current reads when freshness cannot be established independently of caller writes. Add this two-connection test.

3. **[wallet.rb:904](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:904) — `touch` does not guarantee the required change marker.**  
   `has_changes_to_save? ? save! : touch` performs **zero wallet updates** inside `Wallets::Wallet.no_touching` when crediting an already-covered wallet; reproduced against committed code. Even successful touches can leave the compared timestamp/balance pair identical when timestamps repeat. §6 requires “every committed change to a wallet’s ledger writes the wallet row.” Use an unconditional accounting revision update, independent of touch suppression and timestamp precision. Test unchanged-availability credits under `no_touching` and repeated timestamps, including a MySQL reader spending after the hold lapses.

4. **[wallet.rb:790](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:790) — Preserved transfers reload source credits from the stale snapshot.**  
   `includes(:source_transaction)` performs ordinary reads. If T2 credits the sender after T1’s snapshot, T1’s current-read allocator can consume that credit, but the preload cannot see it; `allocation.source_transaction.expires_at` then dereferences nil. §6 requires “mutation-time reads of credits” to have current-read semantics. Carry source expirations from allocation or explicitly current-read the sources. Test a preserved transfer funded by a credit committed after the caller’s first read.

5. **[wallet.rb:249](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:249) — Individual balance calculations mix database snapshots.**  
   `P`, `C`, `R`, and `N` are separate queries; `total_balance` additionally recalculates held terms. With 100 covered, an intervening covered credit of 50 between the P and C queries makes `balance` return −50, although availability remains zero throughout. I reproduced this interleaving. §5 says “each calculation derives its components consistently.” Calculate each reader in one SQL snapshot; pinning time alone is insufficient. Add a synchronized reader-versus-credit test.

6. **[wallet.rb:352](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:352) — Commands still lack their required savepoints.**  
   `self.class.transaction` and the credit/debit `with_lock` calls join caller transactions. Rescuing an inbound transfer failure therefore commits the outbound debit and transfer row; reproduced with sender 100→80 and recipient remaining zero. §6 requires “`requires_new: true` savepoint.” Add command-level savepoints and verify that a rescued late failure leaves no rows, allocations, cache changes, or success callbacks when the caller commits.

7. **[wallet.rb:820](/Users/javi/GitHub/wallets-holds/lib/wallets/models/wallet.rb:820) — D12’s helper signatures changed.**  
   `positive_remaining_balance(at:, lock:)` and `unbacked_negative_balance(scope, lock:)` replace the promised signatures; `current_balance` now passes `at:`. An embedder overriding `def positive_remaining_balance; super; end` raises `ArgumentError`—reproduced. D12 requires both helpers to “keep both signature and meaning.” Restore their signatures and put context parameters in new helpers or the pinned context. Test an embedder retaining the original override signature.

8. **[add_wallets_holds.rb.erb:56](/Users/javi/GitHub/wallets-holds/lib/generators/wallets/templates/add_wallets_holds.rb.erb:56) — Rolling back a no-op upgrade deletes existing holds.**  
   `up` returns when the table exists, but `down` unconditionally executes `drop_table`. The generator still emits this migration on a fresh installation. I reproduced pre-existing holds disappearing after no-op up/down. §9 requires “running it when the table exists is a no-op.” Skip generation for an existing table and ensure rollback cannot drop a table this migration did not create. Extend the existing no-op test through rollback with retained hold rows.

## Should fix

None additional.

## Nits

None.

## Missing tests

- §6/§11: MySQL stale transfers funded by newly committed credits, including recipient-side staleness.
- §6/§11: memo lifetime across nonjoinable outer transactions, savepoint commit/rollback, and caller wallet writes.
- §5/§11: concurrent mutations between components of a single public balance calculation.
- §8/§11: an enabled embedded ledger exercising coverage SQL, allocation, and transaction readers against custom table names.
- §9/§11: explicit 0.2-schema upgrade and preservation of existing holds after no-op upgrade rollback.
- `current_reads_test.rb`’s three named tests establish their simple reservation, coverage, and allocation interleavings; they do not establish the freshness detector’s general correctness or the missing transaction shapes above.

VERDICT: BLOCK