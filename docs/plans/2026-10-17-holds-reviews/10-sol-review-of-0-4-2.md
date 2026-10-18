# Review of the 0.4.2 fix (Codex Sol, 2026-10-18, at commit 92d931c, PR #8)

Scope: `git diff dddd7fa..92d931c`, the fix for a rolled-back command poisoning the wallet or hold instance (`WalletBase#lock!` and `HoldBase#lock!` discard unsaved changes to the columns the ledger writes before locking), its tests and CHANGELOG entry, read-only. Verdict: PASS; the should-fix and both missing tests were applied in the next commit.

## Blocking

None found.

## Should fix

- The usage_credits-shaped test explicitly reloads the wallet before retrying ([line 37](test/models/wallets/rolled_back_command_test.rb:37)), clearing the dirty state itself. Check persisted balance through a separate instance, then retry on the original.

## Nits

- The existing comment above `refresh_cached_balance!` still claims rollback leaves no pending changes ([line 1664](lib/wallets/models/wallet.rb:1664)). Update it to reflect the defect and new recovery seam.

## Missing tests

- Both hold retry tests reload their original instance before retrying ([release](test/models/wallets/rolled_back_command_test.rb:98), [capture](test/models/wallets/rolled_back_command_test.rb:113)). They therefore do not exercise `HoldBase#lock!` clearing rollback dirtiness. Assert database state through another instance.
- Add a hold counterpart to the wallet test proving an unsaved caller-owned attribute still prevents locking.

VERDICT: PASS

0.4.2 appears safe to publish from this static review. The overrides cover the relevant wallet and hold locks; command decisions read the discarded fields after reload. Rails 7.2 and 8.1 signatures, string attribute names, empty restoration lists, and new-record guards are compatible. Timestamp fallback calculations run after reload, and restoration does not invoke save/touch callbacks or clear the remembered stale-snapshot marker. Teardown destroys holds before their referenced transactions. The CHANGELOG matches the implementation; the principal weakness is regression coverage. Tests were not run.
## Disposition (lead)

Applied in the next commit: the regression tests read the database through a fresh instance and retry on the dirty one (before, `reload` cleared the very state under test: against the 0.4.1 models five of the nine tests now error, none before); a hold counterpart of the caller-owned-attribute test; the comment above `refresh_cached_balance!` now says that a rollback does leave the ledger's columns pending and that `lock!` discards them. 571 runs green on SQLite, PostgreSQL and MySQL.
