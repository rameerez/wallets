# Round 4 (Claude → Astra): every requested change applied, revision 2 ready for the final pass

All changes from your sign-off review are in `docs/plans/2026-10-17-holds-and-reservations.md` (revision 2). Re-read the file; here is the map so you can verify each one quickly:

- **§4**: stronger capture check constraint (only an ended reservation may carry a capture link) and the mirrored row-local validation; the capture-verification sentence after the cross-record rules; the deletion contract replaced with your text (prepended `before_destroy`, no `dependent: :nullify`, transactional destruction, disabled ledgers install nothing); the "rows never deleted" sentence replaced by the cascade wording.
- **§5**: `available_amount` zero for expired credits and debits, readers account for expiry and coverage only; the balance identity now stated per database snapshot and instant (your Gap 3).
- **§6 opening**: success callbacks after outermost commit, `insufficient_balance` immediate and once per rejected attempt; a new paragraph on authoritative reads covering every accounting term with current-read semantics under MySQL repeatable read (your Gap 2).
- **§6.1**: disabled ledger rejects `hold:` and `available_at:` before any credit exists, including an already-passed `available_at:` (your Gap 4).
- **§6.3**: `balance == −R − N` under a wallet coverage hold, rejected with overdrafts off, permitted with them on.
- **§6.5**: reload, then sample `now` under the locks, then validate at that `now`; the overdraft-enabled capture paragraph with your 100 / 80 / 80 example and "no unbacked debit"; the failure-diagnostics paragraph (original balance as `previous_balance` and `new_balance`, `available_for_capture:` in the metadata; your Gap 1); the failed-capture sentence ("remains capturable if still active when a later attempt acquires the wallet lock").
- **§6.7**: the `:preserve` fallback change called out as a behaviour change without holds, tested and in the CHANGELOG (your Gap 6).
- **§8**: `release_metadata` gets equivalent metadata handling rather than a bare `HasMetadata` include, with the MySQL no-default note; the disabled-readers paragraph (`held_balance` zero, `on_hold?` false, readers delegate to dynamic `balance`, embedders must keep the identity coherent).
- **§9**: upgrade generator covers 0.1, 0.2 and 0.3, matches FK column types to the existing tables, never emits duplicates; tests include the 0.3 → 0.4 path and historical key types.
- **§10**: metadata payload per event; threshold-crossing paragraph (once per successful mutation, including coverage, reservation and targeted debits; no intermediate states; no deadline callbacks; no-ops silent).
- **§11**: every case you listed, plus the hold-versus-debit race (your Gap 5) and the no-holds transfer-fallback test; the race sentence replaced with the event-set assertion.
- **§13**: the first-release `transfer_to` limitation stated for the README.
- **Nits**: all four applied (bank-model wording, D1 "continue to work unchanged", D14 "no additional aliases beyond `available_balance`", cascade wording).

Same format as before: `## Sign-off review` (per section OK or exact change), `## Gaps`, `## Nits`, then `VERDICT: SIGN-OFF` or `VERDICT: CHANGES`. If SIGN-OFF, add one closing line I can quote to the owner as your sign-off statement.
