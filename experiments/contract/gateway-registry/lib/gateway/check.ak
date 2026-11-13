use aiken/collection/dict
use aiken/collection/list
use aiken/primitive/bytearray
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, Input, Transaction}

// The gateway write check, shared by the two validators:
//   validators/gateway_write.ak     (mint a RECEIPT token)      -> write_allowed
//   validators/gateway_withdraw.ak  (zero-amount withdrawal)    -> withdraw_allowed
// Both demand the same two things: the registry coin is a reference input and an enrolled key signed.

/// The enrolled key hashes in the registry coin, or None if there is not exactly one registry coin among the
/// reference inputs or it has no inline datum.
pub fn enrolled_keys(
  refs: List<Input>,
  registry_policy: PolicyId,
  registry_name: ByteArray,
) -> Option<List<ByteArray>> {
  let registries =
    list.filter(
      refs,
      fn(i) { assets.quantity_of(i.output.value, registry_policy, registry_name) == 1 },
    )
  when registries is {
    [registry] ->
      when registry.output.datum is {
        InlineDatum(d) -> {
          expect keys: List<ByteArray> = d
          Some(keys)
        }
        _ -> None
      }
    _ -> None
  }
}

/// True if at least one required signer is on the enrolled list of the registry coin (reference input).
/// The script fails (not just False) when there is no usable registry coin.
pub fn signed_by_enrolled(
  registry_policy: PolicyId,
  registry_name: ByteArray,
  tx: Transaction,
) -> Bool {
  expect Some(keys) =
    enrolled_keys(tx.reference_inputs, registry_policy, registry_name)
  list.any(tx.extra_signatories, fn(s) { list.has(keys, s) })
}

pub fn write_allowed(
  registry_policy: PolicyId,
  registry_name: ByteArray,
  batch_hash: ByteArray,
  policy_id: PolicyId,
  tx: Transaction,
) -> Bool {
  let signed = signed_by_enrolled(registry_policy, registry_name, tx)
  let receipt_ok =
    ( tx.mint |> assets.tokens(policy_id) |> dict.to_pairs ) == [
      Pair("RECEIPT", 1),
    ]
  signed && receipt_ok && bytearray.length(batch_hash) == 32
}

/// Same check for the zero-withdrawal trigger: no receipt token, only the signer and the 32-byte batch hash.
pub fn withdraw_allowed(
  registry_policy: PolicyId,
  registry_name: ByteArray,
  batch_hash: ByteArray,
  tx: Transaction,
) -> Bool {
  let signed = signed_by_enrolled(registry_policy, registry_name, tx)
  signed && bytearray.length(batch_hash) == 32
}
