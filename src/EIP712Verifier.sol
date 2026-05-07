// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
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

    /// @notice Verify a user's EIP-712 signature on an IntentOrder
    function verifyUserSignature(
        IAppIntentBase.IntentOrder calldata order,
        bytes calldata signature,
        bytes32 domainSeparator
    ) internal pure returns (bool) {
        bytes32 digest = hashOrder(order, domainSeparator);
        address recovered = digest.recover(signature);
        return recovered == order.submittedBy;
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
