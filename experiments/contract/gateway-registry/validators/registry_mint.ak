use aiken/collection/dict
use aiken/collection/list
use cardano/address
use cardano/assets.{Assets, PolicyId}
use cardano/transaction.{Input, Output, OutputReference, Transaction}

// One-shot minting policy for the gateway registry token.
//
// The policy is parameterised with ONE specific transaction output (required_ref) and the token name. It lets a
// transaction mint only if that output is spent in the same transaction. An output can be spent only once, so
// the policy can pass only once: there is exactly one registry token, ever. It also insists that what is minted
// under the policy is exactly one token with the given name (no second token, no other name, no burn).
// After that, the administrator moves the single token (and its inline datum, the enrolled list) from coin to coin
// with ordinary key-signed transactions; the policy is not run again.

validator registry_mint(required_ref: OutputReference, token_name: ByteArray) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    registry_mint_ok(required_ref, token_name, policy_id, tx)
  }

  else(_) {
    fail
  }
}

pub fn registry_mint_ok(
  required_ref: OutputReference,
  token_name: ByteArray,
  policy_id: PolicyId,
  tx: Transaction,
) -> Bool {
  let spends_required =
    list.any(tx.inputs, fn(i: Input) { i.output_reference == required_ref })
  let minted = tx.mint |> assets.tokens(policy_id) |> dict.to_pairs
  spends_required && minted == [Pair(token_name, 1)]
}

// ---------------------------------------------------------------- tests

fn seed() -> OutputReference {
  OutputReference { transaction_id: #"1111111111111111111111111111111111111111111111111111111111111111", output_index: 0 }
}

fn other_ref() -> OutputReference {
  OutputReference { transaction_id: #"1111111111111111111111111111111111111111111111111111111111111111", output_index: 1 }
}

fn own() -> PolicyId {
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}

fn input_of(ref: OutputReference) -> Input {
  Input {
    output_reference: ref,
    output: Output {
      address: address.from_script(
        #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      ),
      value: assets.from_lovelace(5000000),
      datum: transaction.NoDatum,
      reference_script: None,
    },
  }
}

fn mint_tx(inputs: List<Input>, minted: Assets) -> Transaction {
  Transaction { ..transaction.placeholder, inputs: inputs, mint: minted }
}

fn check(inputs: List<Input>, minted: Assets) -> Bool {
  registry_mint_ok(seed(), "GW_REGISTRY", own(), mint_tx(inputs, minted))
}

test accept_seed_spent_and_one_token_minted() {
  check([input_of(other_ref()), input_of(seed())], assets.from_asset(own(), "GW_REGISTRY", 1))
}

test reject_seed_not_spent() {
  !check([input_of(other_ref())], assets.from_asset(own(), "GW_REGISTRY", 1))
}

test reject_no_inputs_at_all() {
  !check([], assets.from_asset(own(), "GW_REGISTRY", 1))
}

test reject_two_tokens_quantity_two() {
  !check([input_of(seed())], assets.from_asset(own(), "GW_REGISTRY", 2))
}

test reject_two_different_names() {
  !check(
    [input_of(seed())],
    assets.from_asset(own(), "GW_REGISTRY", 1)
      |> assets.add(own(), "SECOND", 1),
  )
}

test reject_wrong_name() {
  !check([input_of(seed())], assets.from_asset(own(), "OTHER", 1))
}

test reject_burn() {
  !check([input_of(seed())], assets.from_asset(own(), "GW_REGISTRY", -1))
}

test reject_extra_token_under_the_policy() {
  !check(
    [input_of(seed())],
    assets.from_asset(own(), "GW_REGISTRY", 1)
      |> assets.add(own(), "EXTRA", 1),
  )
}

test accept_other_policy_token_alongside() {
  // a token of ANOTHER policy in the same mint is not this policy's business (its own policy decides)
  check(
    [input_of(seed())],
    assets.from_asset(own(), "GW_REGISTRY", 1)
      |> assets.add(
          #"dddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
          "X",
          1,
        ),
  )
}
