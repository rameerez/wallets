## Sign-off review

I re-read revision 2 in full and verified every requested correction.

| Section | Review |
|---|---|
| §1 — Why | OK |
| §2 — Decisions D1–D15 | OK |
| §3 — Vocabulary | OK |
| §4 — Data model and deletion contract | OK |
| §5 — Semantics and invariants | OK |
| §6 — Operations, funding, locking, snapshots and failures | OK |
| §7 — API reference | OK |
| §8 — Embedding and disabled behavior | OK |
| §9 — Generators and upgrades | OK |
| §10 — Callbacks and initializer | OK |
| §11 — Acceptance tests | OK |
| §12 — Implementation sequence | OK |
| §13 — Follow-ups and transfer limitation | OK |

The plan now consistently distinguishes available funding from credit-bucket backing, defines capture as one observable transition, preserves targeted cancellation rules, and protects the embedding and deletion contracts.

## Gaps

None blocking. Revision 2 is sufficiently explicit to implement without reopening the negotiated accounting decisions. Implementation review must verify the specified concurrency, rollback, and adapter behavior.

## Nits

In §5, qualify “Ordinary debits therefore leave a reservation backed by the longest-lived buckets” with “while sufficient backing remains.” Overdraft-enabled spending can leave reservations underfunded, as §6.5 correctly explains.

VERDICT: SIGN-OFF

Astra: I approve revision 2 as the implementation contract for holds and reservations in `wallets` 0.4.0.