// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./interfaces/IAppIntentBase.sol";
import "./interfaces/IValidatorRegistry.sol";

/// @title EIP712Verifier - EIP-712 typed data verification for intent orders
/// @notice Handles user signature verification and validator approval signing
library EIP712Verifier {
    using ECDSA for bytes32;

    // EIP-712 type hashes
    bytes32 internal constant INTENT_ORDER_TYPEHASH = keccak256(
        "IntentOrder(bytes32 orderId,address app,bytes4 intentSelector,bytes32 paramsHash,address submittedBy,uint256 chainId,uint256 deadline,uint256 nonce,bool perpetual,uint256 maxExecutions,uint256 cooldown)"
    );

    bytes32 internal constant PLAN_APPROVAL_TYPEHASH = keccak256(
        "PlanApproval(bytes32 orderId,bytes32 planHash,uint256 score)"
    );

    bytes32 internal constant PLAN_SET_APPROVAL_TYPEHASH = keccak256(
        "PlanSetApproval(bytes32 orderId,bytes32 planSetHash)"
    );

    /// @notice Chain-agnostic domain for plan-set approvals.
    /// @dev A multi-leg intent's legs execute on DIFFERENT chains, each app
    ///      deployment having its own chainId+verifyingContract-bound
    ///      DOMAIN_SEPARATOR — a signature over any one of them could never
    ///      verify on the others, forcing one wallet prompt per chain. The
    ///      plan-set approval instead uses this fixed name+version domain so
    ///      ONE signature covers every leg. Scope safety does not come from
    ///      the domain: the struct binds orderId + the exact ordered plan
    ///      hashes (which bind per-chain targets/calldata), per-leg replay is
    ///      keyed by legExecuted, and every leg still passes the validator
    ///      quorum + _handleIntent min-out gauntlet. Replaying the approval
    ///      elsewhere can only authorize executing the very plans the user
    ///      approved.
    bytes32 internal constant PLAN_SET_DOMAIN_SEPARATOR = keccak256(abi.encode(
        keccak256("EIP712Domain(string name,string version)"),
        keccak256("MinotaurPlanSet"),
        keccak256("1")
    ));

    /// @notice Hash an IntentOrder for EIP-712 signing
    function hashOrder(
        IAppIntentBase.IntentOrder calldata order,
        bytes32 domainSeparator
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            INTENT_ORDER_TYPEHASH,
            order.orderId,
            order.app,
            order.intentSelector,
            keccak256(order.intentParams),
            order.submittedBy,
            order.chainId,
            order.deadline,
            order.nonce,
            order.perpetual,
            order.maxExecutions,
            order.cooldown
        ));
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    /// @notice Verify a user's EIP-712 signature on an IntentOrder.
    /// @dev Accepts both EOA (ECDSA) and smart-account (ERC-1271) signatures via
    ///      OZ SignatureChecker, and normalizes a non-canonical recovery byte
    ///      (v in {0,1} -> {27,28}) for 65-byte EOA signatures. Previously this
    ///      used strict ECDSA.recover, which rejected v not in {27,28} (the 0/1
    ///      form emitted by viem/ethers low-level paths, several hardware wallets,
    ///      and WalletConnect) and had no ERC-1271 path, so Coinbase Smart Wallet /
    ///      Safe accounts (common on Base) could not transact at all. See #229.
    ///      `view` (not `pure`) because the ERC-1271 path makes a staticcall.
    function verifyUserSignature(
        IAppIntentBase.IntentOrder calldata order,
        bytes calldata signature,
        bytes32 domainSeparator
    ) internal view returns (bool) {
        bytes32 digest = hashOrder(order, domainSeparator);
        bytes memory sig = signature;
        // Normalize the recovery byte only for a standard 65-byte ECDSA signature;
        // ERC-1271 signatures use account-defined encodings and are passed through.
        if (sig.length == 65) {
            uint8 v = uint8(sig[64]);
            if (v < 27) {
                sig[64] = bytes1(v + 27);
            }
        }
        return SignatureChecker.isValidSignatureNow(order.submittedBy, digest, sig);
    }

    /// @notice Hash a plan-set approval for user signing (chain-agnostic domain).
    /// @param planSetHash keccak256(abi.encodePacked(orderedLegPlanHashes)) —
    ///        every leg of the multi-leg intent, forward legs first then
    ///        revert/rollback legs, each hashed with hashPlan. The platform
    ///        compiles this ordering; the user's wallet displays and signs it
    ///        once at quote acceptance.
    function hashPlanSetApproval(
        bytes32 orderId,
        bytes32 planSetHash
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            PLAN_SET_APPROVAL_TYPEHASH,
            orderId,
            planSetHash
        ));
        return MessageHashUtils.toTypedDataHash(PLAN_SET_DOMAIN_SEPARATOR, structHash);
    }

    /// @notice Verify a user's signature over a plan-set approval.
    /// @dev Same signature handling as verifyUserSignature: EOA (ECDSA) and
    ///      smart-account (ERC-1271) via SignatureChecker, with v∈{0,1}
    ///      normalization for 65-byte signatures (#229).
    function verifyPlanSetSignature(
        address signer,
        bytes32 orderId,
        bytes32 planSetHash,
        bytes calldata signature
    ) internal view returns (bool) {
        bytes32 digest = hashPlanSetApproval(orderId, planSetHash);
        bytes memory sig = signature;
        if (sig.length == 65) {
            uint8 v = uint8(sig[64]);
            if (v < 27) {
                sig[64] = bytes1(v + 27);
            }
        }
        return SignatureChecker.isValidSignatureNow(signer, digest, sig);
    }

    /// @notice Hash a plan approval for validator signing
    function hashPlanApproval(
        bytes32 orderId,
        bytes32 planHash,
        uint256 score,
        bytes32 domainSeparator
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            PLAN_APPROVAL_TYPEHASH,
            orderId,
            planHash,
            score
        ));
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    /// @notice Verify validator signatures with sorted address check
    /// @dev Signatures must be from unique validators, sorted by address
    function verifyValidatorSignatures(
        bytes32 orderId,
        bytes32 planHash,
        uint256 score,
        bytes[] calldata signatures,
        address validatorRegistry,
        bytes32 domainSeparator
    ) internal view returns (uint256 validCount) {
        bytes32 digest = hashPlanApproval(orderId, planHash, score, domainSeparator);

        address lastSigner = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = digest.recover(signatures[i]);

            // Must be a registered validator
            if (!IValidatorRegistry(validatorRegistry).isValidator(signer)) continue;

            // Must be sorted (prevents duplicates)
            if (signer <= lastSigner) continue;

            lastSigner = signer;
            validCount++;
        }
    }

    /// @notice Hash an execution plan (calldata version — used in production)
    function hashPlan(
        IAppIntentBase.ExecutionPlan calldata plan
    ) internal pure returns (bytes32) {
        bytes32[] memory callHashes = new bytes32[](plan.calls.length);
        for (uint256 i = 0; i < plan.calls.length; i++) {
            callHashes[i] = keccak256(abi.encode(
                plan.calls[i].target,
                plan.calls[i].value,
                keccak256(plan.calls[i].callData)
            ));
        }
        return keccak256(abi.encode(
            keccak256(abi.encodePacked(callHashes)),
            plan.deadline,
            plan.nonce,
            keccak256(plan.metadata)
        ));
    }

    /// @notice Hash an execution plan (memory version — used in tests)
    function hashPlanMem(
        IAppIntentBase.ExecutionPlan memory plan
    ) internal pure returns (bytes32) {
        bytes32[] memory callHashes = new bytes32[](plan.calls.length);
        for (uint256 i = 0; i < plan.calls.length; i++) {
            callHashes[i] = keccak256(abi.encode(
                plan.calls[i].target,
                plan.calls[i].value,
                keccak256(plan.calls[i].callData)
            ));
        }
        return keccak256(abi.encode(
            keccak256(abi.encodePacked(callHashes)),
            plan.deadline,
            plan.nonce,
            keccak256(plan.metadata)
        ));
    }
}
