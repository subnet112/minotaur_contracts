# Minotaur Contracts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Solidity 0.8.24](https://img.shields.io/badge/solidity-0.8.24-363636.svg)](https://soliditylang.org/)
[![Subnet 112](https://img.shields.io/badge/bittensor-subnet112-purple)](https://github.com/subnet112/minotaur_subnet)

Platform smart contracts for [Subnet 112 (Minotaur)](https://github.com/subnet112/minotaur_subnet) — the Bittensor subnet for distributed intent execution.

This repository hosts the **generic platform contracts** that every Minotaur App (DexAggregator, DCA, etc.) inherits from. App-specific contracts live in [subnet112/minotaur-apps](https://github.com/subnet112/minotaur-apps).

## Contracts

| Contract | Role |
|---|---|
| `AppIntentBase.sol` | Abstract base every App inherits. Validator quorum verification, EIP-712 user-signature checks, ephemeral CREATE2 proxy execution, replay protection, platform-fee plumbing. |
| `EphemeralProxy.sol` | Single-use proxy deployed per intent execution. Isolates token state between unrelated orders. |
| `EIP712Verifier.sol` | EIP-712 typed-data hashing for `IntentOrder` and `PlanApproval` structs. Library, not deployed. |
| `ValidatorRegistry.sol` | On-chain registry of validator hotkeys and quorum settings. Apps query it to validate signatures. |
| `ChampionRegistry.sol` | On-chain attestation of champion solvers. Used as a trustless gate by the solver-repo's auto-merge GitHub Action. |
| `interfaces/` | Lightweight interface ABIs for off-chain consumers and inheriting contracts. |

## Building

Dependencies (OpenZeppelin, forge-std, Uniswap V3 core/periphery) are tracked as
git submodules under `lib/`. Clone with `--recursive`, or fetch them after a
plain clone:

```bash
git clone --recursive https://github.com/subnet112/minotaur_contracts.git
# or, if you already cloned without --recursive:
git submodule update --init --recursive

# Build
forge build

# Run tests
forge test -v
```

Standard Foundry layout — `foundry.toml` declares `src`, `out`, `lib`, and the
OZ + Uniswap remappings.

## Inheriting `AppIntentBase`

Apps in [subnet112/minotaur-apps](https://github.com/subnet112/minotaur-apps) consume this repo as a Foundry dependency:

```bash
forge install subnet112/minotaur_contracts
```

Then in Solidity:

```solidity
import "minotaur_contracts/src/AppIntentBase.sol";

contract YourApp is AppIntentBase {
    bytes4 public constant YOUR_INTENT_SELECTOR = bytes4(keccak256("yourIntent(...)"));

    constructor(/* ... */) AppIntentBase(/* ... */) {
        registeredIntents[YOUR_INTENT_SELECTOR] = true;
    }

    function _handleIntent(IntentOrder calldata o, ExecutionPlan calldata p)
        internal override returns (uint256 score, bool valid)
    {
        if (o.intentSelector == YOUR_INTENT_SELECTOR) {
            return _yourIntent(o, p);
        }
        revert("Unknown intent");
    }
}
```

`_handleIntent` is the only function an app must implement. The base class does the rest — signature verification, quorum check, proxy deployment, plan execution, scoring threshold gate.

## Deploying

Apps are deployed permissionlessly through the validator API rather than directly via `forge create` — the relayer pays gas, the developer pays nothing on-chain. See the [main subnet repo](https://github.com/subnet112/minotaur_subnet) for the deployment flow.

For the platform contracts themselves (`ValidatorRegistry`, `ChampionRegistry`), the deploy scripts under `script/` cover the canonical chain set. These are run manually by the subnet operator at chain bring-up.

## License

MIT — see [LICENSE](./LICENSE).
