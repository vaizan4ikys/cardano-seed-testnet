# spec

Inputs for `scripts/gen-testnet.sh`, which turns them into the real genesis files.

| File | Content |
|---|---|
| `shelley-spec.json` | the main chain parameters (below) |
| `alonzo-spec.json`, `conway-spec.json` | Plutus cost models, governance parameters |
| `config.json` | node configuration: all eras start at epoch 0, so the chain runs Conway from slot 0 |

Main parameters in `shelley-spec.json`:

| Parameter | Value | Meaning |
|---|---|---|
| `slotLength` | 1 | one slot per second |
| `activeSlotsCoeff` (f) | 0.2 | on average 1 slot in 5 gets a block, so about one block per 5 s |
| `securityParam` (k) | 60 | a block more than 60 blocks deep can no longer be rolled back |
| `epochLength` | 3000 | slots per epoch (50 minutes) |
| `maxTxSize` | 16384 | transaction limit, 16 KB |

The network magic in the spec is replaced by `--testnet-magic` (42 for network 1, 43 for network 2).
