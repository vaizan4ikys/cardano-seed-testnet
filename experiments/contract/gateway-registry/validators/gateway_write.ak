use cardano/address
use cardano/assets.{PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use gateway/check.{write_allowed}

// Gateway write check (Phase 0/2 of the plan). The check itself lives in lib/gateway/check.ak.
//
// A data transaction (the one that carries the sensor readings in its metadata) also mints ONE receipt token
// under this policy. The policy lets that happen only if
//   1. the registry coin is attached as a REFERENCE input (so it is not spent and gateways do not block each other),
//      it carries the registry token (exact policy id + name) and its inline datum is the list of enrolled key hashes,
//   2. at least one of the transaction's required signers is on that list,
//   3. exactly one receipt "RECEIPT" is minted (a constant name: the change output does not grow with every receipt),
//   4. the redeemer is a 32-byte batch hash (the script cannot read the metadata; the page checks the hash off-chain).

validator gateway_write(registry_policy: PolicyId, registry_name: ByteArray) {
  mint(batch_hash: ByteArray, policy_id: PolicyId, tx: Transaction) {
    write_allowed(registry_policy, registry_name, batch_hash, policy_id, tx)
  }

  else(_) {
    fail
  }
}

// ---------------------------------------------------------------- tests

fn reg_policy() -> PolicyId {
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}

fn own_policy() -> PolicyId {
  #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}

fn gw_a() -> ByteArray {
  #"01010101010101010101010101010101010101010101010101010101"
}

fn gw_b() -> ByteArray {
  #"02020202020202020202020202020202020202020202020202020202"
}

fn hash32() -> ByteArray {
  #"0000000000000000000000000000000000000000000000000000000000000000"
}

// registry coin with the given token policy, name and datum
fn registry_input(policy: PolicyId, name: ByteArray, enrolled: List<ByteArray>) -> Input {
  Input {
    output_reference: OutputReference { transaction_id: "", output_index: 0 },
    output: Output {
      address: address.from_script(
        #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      ),
      value: assets.from_asset(policy, name, 1),
      datum: InlineDatum(enrolled),
      reference_script: None,
    },
  }
}

fn data_tx(refs: List<Input>, signers: List<ByteArray>, qty: Int) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    reference_inputs: refs,
    extra_signatories: signers,
    mint: assets.from_asset(own_policy(), "RECEIPT", qty),
  }
}

fn check(refs: List<Input>, signers: List<ByteArray>, qty: Int, hash: ByteArray) -> Bool {
  write_allowed(reg_policy(), "GW_REGISTRY", hash, own_policy(), data_tx(refs, signers, qty))
}

test accept_enrolled_gateway() {
  check(
    [registry_input(reg_policy(), "GW_REGISTRY", [gw_a()])],
    [gw_a()],
    1,
    hash32(),
  )
}

test accept_when_one_of_several_signers_is_enrolled() {
  check(
    [registry_input(reg_policy(), "GW_REGISTRY", [gw_a()])],
    [gw_b(), gw_a()],
    1,
    hash32(),
  )
}

test reject_unenrolled_gateway() {
  !check(
    [registry_input(reg_policy(), "GW_REGISTRY", [gw_a()])],
    [gw_b()],
    1,
    hash32(),
  )
}

test reject_revoked_gateway_empty_list() {
  !check(
    [registry_input(reg_policy(), "GW_REGISTRY", [])],
    [gw_a()],
    1,
    hash32(),
  )
}

test reject_no_signer() {
  !check(
    [registry_input(reg_policy(), "GW_REGISTRY", [gw_a()])],
    [],
    1,
    hash32(),
  )
}

test reject_two_receipts() {
  !check(
    [registry_input(reg_policy(), "GW_REGISTRY", [gw_a()])],
    [gw_a()],
    2,
    hash32(),
  )
}

test reject_bad_hash_length() {
  !check(
    [registry_input(reg_policy(), "GW_REGISTRY", [gw_a()])],
    [gw_a()],
    1,
    #"00",
  )
}

// no registry among the reference inputs: the script fails
test reject_missing_registry() fail {
  check([], [gw_a()], 1, hash32())
}

// a look-alike token with the right name under ANOTHER policy is not the registry
test reject_fake_registry_other_policy() fail {
  check(
    [registry_input(#"dddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "GW_REGISTRY", [gw_a()])],
    [gw_a()],
    1,
    hash32(),
  )
}

// two registry coins attached: ambiguous, rejected
test reject_two_registries() fail {
  check(
    [
      registry_input(reg_policy(), "GW_REGISTRY", [gw_a()]),
      registry_input(reg_policy(), "GW_REGISTRY", [gw_a()]),
    ],
    [gw_a()],
    1,
    hash32(),
  )
}
