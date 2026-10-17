# Round 3 (Claude → Astra): both accounting decisions accepted; the plan is ready for your sign-off

Your two open questions, answered:

1. **Signed availability: accepted.** The unconditional `balance >= 0` validation goes; the cache validates as a signed integer; commands enforce funding under lock; the configuration contract is reworded exactly as you proposed. Your reserve-80-then-cover-100 example and the expiry case are in the acceptance tests.
2. **Targeted allocation funding rule: accepted** as written: `amount − covered_consumed ≤ max(available_before, 0)` with overdrafts off; always fully allocated to named, unexpired sources; no FEFO or unbacked fallback; expired sources rejected under every expiration policy; `:preserve` fallback decided by the actual unbacked portion.

Also taken as written: composite capture snapshots, the capture terminal and retry rules, `on_hold?` meaning wallet-scoped coverage only, `held_balance` allowed to exceed `total_balance`, explicit `hold`/`reserve` rejecting an already-reached `until:`, the `coverage` / `reservations` scopes and `reservation?`, the deletion-contract test with both FKs, and your full acceptance-test list.

## The plan

Written to the repo you are in: **`docs/plans/2026-10-17-holds-and-reservations.md`**. Read it in full. It is the artifact the owner will build from, so review it as the implementation contract, not as a summary of our conversation: every decision (D1–D15), the vocabulary, the schema with checks and indexes and the deletion contract, the balance formulas and invariants, every operation with its lock, instant, funding rule, snapshot and callback behaviour, the API table, embedding, generators, callbacks, the acceptance-test list, the implementation sequence, and the follow-ups.

Two things in it you have not seen before, both small, both flagged for you to accept or strike:

- §4 deletion contract: `has_many :holds, dependent: :destroy` declared **before** `has_many :transactions` on the wallet so holds cascade first; `Transaction has_one :captured_reservation, dependent: :nullify` as belt and braces.
- §13 follow-ups: inbound holds on `transfer_to` (pending marketplace payouts) listed as a 0.4.x follow-up, not in 0.4.0.

## What I need from you

Review the plan for sign-off. Reply in this format:

1. `## Sign-off review` — for each section of the plan, either "OK" or the exact change required (quote the sentence, give the replacement).
2. `## Gaps` — anything the implementation would need that the plan does not say. Be specific: a missing rule, a missing test, an ambiguous sentence.
3. `## Nits` — wording or naming you would improve but would not block on.
4. End with exactly one line: `VERDICT: SIGN-OFF` if the plan can be implemented as written (nits allowed), or `VERDICT: CHANGES` if a listed change is required first.

If you give CHANGES, I apply them to the file and send it back for a final pass.
