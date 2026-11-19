# Phase 0 notes: gateway registry and write check on the private chain

Chain: net-1 on seedvm, magic 42, Conway era, protocol version 9, about 5 s per block, 3 pools.
Everything below is run by `./p0.sh` (or its single scripts) against pool 1's container. Nothing is committed.
Work files (keys, transactions) are inside the container, in the work dir `P0_DIR` (the final, current setup is `/tmp/p0n`).
Secret keys never leave the container and are never printed.

## What was wrong in the first version, and how it is fixed

1. **Two live registry coins, and more could be minted.** The first version minted the registry token with a plain
   "the admin key signs" native script, and that admin was the genesis key `utxo1`. Anyone holding that key (the load,
   gateway and measure tools use it too) could mint more registry tokens, and a full re-run of `p0.sh` did exactly that:
   it created a second live registry coin. The write check only asks for "exactly one registry coin among the reference
   inputs", so a gateway listed in either coin could write, and revoking a gateway in one coin did nothing.
   **Fix:** the registry token is now minted through a one-shot Plutus policy (`validators/registry_mint.ak`).
   It is parameterised with one specific output (the "seed", a coin of the new administrator) and the token name; it passes only
   if the seed is spent in the same transaction and exactly one token with that name is minted (no second token, no
   other name, no burn). A coin can be spent once, so there can never be a second registry token.
   `gateway_write` and `gateway_withdraw` are built with the NEW registry policy id.
2. **Administrator = shared genesis key.** **Fix:** `p0-admin.sh` makes a dedicated administrator key inside the container
   (mode 600), funds it once from `utxo1` (400 ADA seed coin + a separate 10 ADA collateral coin), and from then on every
   registry transaction (mint, revoke, restore, gateway funding) is signed by that key. `utxo1` is not used by the registry any more.
3. **Old registry coins stay on the chain** (they cannot be removed) but are inert: see "Old registry coins" below.
4. **Scripts are safer to re-run.** (Checked: a second full `p0.sh` run on `/tmp/p0n` skipped funding and minting, and `P0_DIR=/etc FRESH=1` is refused.) `rm -rf` of the work dir only happens with `FRESH=1` and only for `/tmp/<name>`; the scripts use
   `set -eu` so an internal failure stops `p0.sh`; with a live `registry.ref` no second registry is minted.

## Current registry (work dir /tmp/p0n)

* Registry policy id (one-shot Plutus V3, `registry_mint`): `27780ed01118cada10fe46572b824899ad927184225df7bd5ff6be0d`, token `GW_REGISTRY`.
* Seed coin (spent by the mint): `89c0ed81b720a1af35e00b48bd4133a8748569e18a0c812a91034b6c45309f1b#0`.
* First registry coin: `c9099cfe...#0`; current coin when this was written: `dc75dfa1...#0`. The current coin changes with every revoke/restore: it is always in `/tmp/p0n/registry.ref`, and the full history (with the policy id and what was enrolled) is in `/tmp/p0n/registry.history`.
* gateway_write policy id `4007b3ca...` and gateway_withdraw script hash `78a05615...` carry this registry policy id as a parameter.
* How to tell the current registry coin from an obsolete one: it holds a token of policy `27780ed0...` (the content of `registry.policy.aiken` / `policy.id`). Obsolete coins hold a token named `GW_REGISTRY` under another policy.

## Old registry coins (obsolete, inert, left on the chain)

| Where | Policy of the token | Coin(s) | Note |
|---|---|---|---|
| first run, work dir `/tmp/p0` | `cb762a53...` (native "utxo1 signs") | `cc9a47da...#0` (current of that run; earlier ones spent) | first version, gateway_write `03f192a0...` / `356876de...` |
| clean re-run, work dir `/tmp/p0v` | `cb762a53...` | `54b704bb...#0` | the second live registry |
| look-alike made in /tmp/p0n by `p0-guards.sh` | `9d9a4239...` (native "p0n admin signs") | `e6070dd4...#0` | lists gateway A of /tmp/p0n on purpose |

Receipt tokens and stake credentials from the earlier runs (policies `03f192a0...`, `356876de...`; stake credentials `a028f245...`, `e841f253...`, deposit 400,000 each) are obsolete too.
Why they are inert: `gateway_write` only counts a reference input as the registry if it holds the token under the registry policy id it was built with; a coin of another policy is invisible to it. Proven at the node (below).

## Task 1: the node itself refuses gateway B (fresh numbers, /tmp/p0n)

Recipe: `transaction build-raw` with `--protocol-params-file`, `--mint-execution-units`, a collateral coin, `--tx-total-collateral`, `--tx-out-return-collateral`, `--read-only-tx-in-reference`, `--required-signer-hash`, metadata; sign with the gateway key; `transaction submit`.
In cardano-cli 11.2.3 the units flags take `(STEPS,MEMORY)`: steps first.

* Declared units: 26,100,000 steps / 81,000 memory (about 10 % above need).
* Gateway B (not enrolled), refused at submit by the node: `ConwayUtxowFailure (UtxoFailure (UtxosFailure (ValidationTagMismatch Phase2Valid (FailedUnexpectedly (PlutusFailure ... CekError ... explicit use of 'error'. Caused by: error`. Nothing reaches the mempool, so no collateral is taken.
* Gateway A, same recipe: accepted, in a block. Size 1,325 bytes, fee 7,882 lovelace.
* Units measured by the node for A's tx: 23,653,611 steps / 74,016 memory. `transaction build` (client side) gives fee 7,601 because it uses the exact units.
* Fee rule: `1 * size + 0 + 0.0577 * memory + 0.0000721 * steps` (1325 + 4673.7 + 1881.8 = 7880.5 for the declared units; the tool gives 7,882 because it measures a draft that is 2 bytes longer, so it never under-estimates). Collateral = ceil(1.5 * fee).
* Size: a script transaction is about 1.3 KB (1,323 to 1,325 bytes); a plain metadata transaction with the same data and no script is only 342 bytes. The difference (about 1 KB) is the script itself (about 690 bytes), the redeemer, the collateral and return-collateral, the reference input and the required signer. A reference script instead of the script in every tx would remove the 690 bytes (not tried here; measured later in Phase 3: 1,633 bytes with a reference script against 2,289 with the script inside, for a 100-reading batch, see `PHASE3-RESULTS.md`).

## Task 2: five chained script transactions (fresh run)

Each tx spends the change output of the previous one (and carries the growing receipt count), same reference input, same collateral coin (never spent). All five built offline in 1.46 s, then submitted in a row: 13 ms each, all five in 62 ms.
* All five accepted by the mempool and all five in the SAME block (block 737, seen 0.97 to 1.11 s after submit). No failure.
* Earlier runs: same result every time (all five in one block); time to the block between 1.0 s and 16.8 s (block lottery).
* A block holds about 49 txs of this size (65,536 B body limit / 1.3 kB); the memory budget would allow about 830.

## Task 3: revocation and restore (fresh run)

The dedicated administrator spends the registry coin (it sits at the admin address, one key witness) and sends the token + inline datum `{"list":[]}` to a new output. Fee 248 lovelace. Restore: same with `[gwA]`, fee 281. Only the registry coin is spent.
* (a) A's data tx referencing the NEW (empty) registry coin: refused by the node, same Plutus failure as for B.
* (b) A's data tx prepared before the revocation (references the old coin), submitted after it: refused at submit, `UtxoFailure (BadInputsUTxO (NonEmptySet (fromList [TxIn c9099cfe...#0])))` (the missing reference input is reported as a bad input).
* (c) Submit of the revoke tx until the new coin is in a block: 7.8 s this run (second full run: 0.6 s; earlier runs: 10.7, 1.7, 0.7 s). Restore: 5.3 s this run (second run 0.6 s; earlier 3.2, 2.1 s). Revocation takes effect with the next block: 1 to 11 s here.
  Same-second behaviour: D1 (references the old coin) submitted 13 ms BEFORE the revoke tx: both accepted by the mempool, both in the same block, D1 valid. D2 submitted 26 ms AFTER the revoke tx: refused at once (the old coin is already spent in the mempool state). This is what the reviewer predicted. I could not read the order inside the block, only that both were in it and D1 was valid.
* Smoke test after restore: A writes again, in a block.

## Guards (`p0-guards.sh`, proven at the node)

* G1: with the registry already minted, the administrator tries to mint a second `GW_REGISTRY` token under `registry_mint` (spending another coin as input, made-up units): refused by the node (Plutus failure: the seed is not spent).
* G2: A's data tx referencing an old-policy registry coin is refused by the node (same Plutus failure as above, "no usable registry coin") for all three: the look-alike (policy `9d9a4239...`, its datum lists A), and the two real old coins (policy `cb762a53...`). Control: the same tx referencing the current registry passes the script (74,016 memory / 23,653,611 steps measured, not submitted).
* Not tried: spending or burning the old coins (not allowed in this task).

## Task 4 (stretch): zero-withdrawal trigger

Works on protocol version 9.
* Stake address of the script: `stake_test17pu2q4s4...`. Registration is a certificate with deposit (400,000 lovelace); in Conway it needs the script as a witness. A plain certificate is refused (`MissingScriptWitnessesUTXOW`), so the validator has a `publish` handler (registration and delegation allowed, nothing else; deregistration is not, so the deposit cannot be taken back). Registration with the script witness: accepted, fee 2,634.
* Data tx with `--withdrawal <stake address>+0`: A accepted; B (not enrolled) refused by the node with the same Plutus failure.
* DRep delegation: at protocol version 9 the withdrawal worked with no delegation at all (`voteDelegation: null`). What happens from protocol version 10 on was NOT tested and is not claimed here. CIP-181 is only a proposal and was not checked.
* Cost, same recipe (units measured by the node plus 2 %): withdraw version 63,798 memory / 19,300,871 steps, size 1,323 bytes, fee 6,499. Mint version 74,016 / 23,653,611, size 1,325 bytes, fee 7,422. So the withdraw trigger is about 12 % cheaper and adds no token to the change output.

## Tests

`aiken check`: 27 checks, 0 errors (gateway_write 10, gateway_withdraw 8, registry_mint 9: accept; seed not spent; no inputs; quantity 2; two names; wrong name; burn; extra token under the policy; token of another policy alongside).
The registry policy id from `aiken blueprint policy` is compared with `cardano-cli transaction policyid` in `p0-registry.sh`; they match.

## Not verified / still open

* Protocol version 10 and later (see task 4).
* Order of transactions inside one block: only inferred.
* The `publish` handler lets anyone register or delegate the credential; fine for a test, tighten if the design is used.
* The "fresh chain" run is a fresh work dir on this same chain (an empty chain was not available).
* The old registry coins, receipts and stake credentials remain on the chain; they are inert but cannot be removed.
