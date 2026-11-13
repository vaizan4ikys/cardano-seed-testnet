use cardano/address.{Credential}
use cardano/assets.{PolicyId}
use cardano/certificate.{Certificate, DelegateCredential, RegisterCredential}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use gateway/check.{withdraw_allowed}
use cardano/address as addr
use cardano/certificate

// Zero-withdrawal trigger (Phase 0, stretch task). The data transaction does not mint a receipt token; it
// withdraws 0 lovelace from the stake address of THIS script, which makes the ledger run the script. The check is
// the same as for gateway_write (registry coin as reference input, an enrolled key among the required signers,
// redeemer = 32-byte batch hash) minus the receipt token. Nothing is added to any output.

validator gateway_withdraw(registry_policy: PolicyId, registry_name: ByteArray) {
  withdraw(batch_hash: ByteArray, _account: Credential, tx: Transaction) {
    withdraw_allowed(registry_policy, registry_name, batch_hash, tx)
  }

  // A script stake credential must be registered with a certificate WITH deposit, and in Conway that certificate needs
  // the script as a witness, so the script has to say yes to it. We allow registration and delegation and nothing
  // else (no deregistration). Delegation is allowed only as a precaution: the zero withdrawal worked on protocol
  // version 9 without any delegation. Whether later protocol versions want a DRep delegation for such a withdrawal
  // was NOT tested here (CIP-181 is only a proposal; its content was not checked).
  publish(_redeemer: Data, cert: Certificate, _tx: Transaction) {
    publish_allowed(cert)
  }

  else(_) {
    fail
  }
}

pub fn publish_allowed(cert: Certificate) -> Bool {
  when cert is {
    RegisterCredential { .. } -> True
    DelegateCredential { .. } -> True
    _ -> False
  }
}

// ---------------------------------------------------------------- tests

fn reg_policy() -> PolicyId {
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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

fn registry_input(enrolled: List<ByteArray>) -> Input {
  Input {
    output_reference: OutputReference { transaction_id: "", output_index: 0 },
    output: Output {
      address: addr.from_script(
        #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      ),
      value: assets.from_asset(reg_policy(), "GW_REGISTRY", 1),
      datum: InlineDatum(enrolled),
      reference_script: None,
    },
  }
}

fn check(refs: List<Input>, signers: List<ByteArray>, hash: ByteArray) -> Bool {
  let tx =
    Transaction {
      ..transaction.placeholder,
      reference_inputs: refs,
      extra_signatories: signers,
    }
  withdraw_allowed(reg_policy(), "GW_REGISTRY", hash, tx)
}

test accept_enrolled_gateway() {
  check([registry_input([gw_a()])], [gw_a()], hash32())
}

test reject_unenrolled_gateway() {
  !check([registry_input([gw_a()])], [gw_b()], hash32())
}

test reject_revoked_gateway_empty_list() {
  !check([registry_input([])], [gw_a()], hash32())
}

test reject_no_signer() {
  !check([registry_input([gw_a()])], [], hash32())
}

test reject_bad_hash_length() {
  !check([registry_input([gw_a()])], [gw_a()], #"00")
}

test reject_missing_registry() fail {
  check([], [gw_a()], hash32())
}

test publish_register_ok() {
  publish_allowed(
    RegisterCredential { credential: addr.Script("x"), deposit: Never },
  )
}

test publish_unregister_refused() {
  !publish_allowed(
    certificate.UnregisterCredential {
      credential: addr.Script("x"),
      refund: Never,
    },
  )
}
