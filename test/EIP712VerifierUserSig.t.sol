// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/EIP712Verifier.sol";
import "../src/interfaces/IAppIntentBase.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// Thin harness exposing the internal library function for direct testing.
contract VerifierHarness {
    bytes32 public immutable DS;

    constructor(bytes32 ds) {
        DS = ds;
    }

    function verify(IAppIntentBase.IntentOrder calldata order, bytes calldata sig)
        external
        view
        returns (bool)
    {
        return EIP712Verifier.verifyUserSignature(order, sig, DS);
    }

    function digestOf(IAppIntentBase.IntentOrder calldata order) external view returns (bytes32) {
        return EIP712Verifier.hashOrder(order, DS);
    }
}

/// Minimal ERC-1271 smart account: valid iff the signature recovers to `owner`.
contract MockSmartAccount {
    using ECDSA for bytes32;

    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err, ) = hash.tryRecover(sig);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) {
            return 0x1626ba7e; // ERC-1271 magic value
        }
        return 0xffffffff;
    }
}

contract EIP712VerifierUserSigTest is Test {
    VerifierHarness harness;
    bytes32 constant DS = keccak256("test-domain-separator");

    address user;
    uint256 userKey;

    function setUp() public {
        harness = new VerifierHarness(DS);
        (user, userKey) = makeAddrAndKey("user");
    }

    function _order(address submittedBy) internal view returns (IAppIntentBase.IntentOrder memory) {
        return IAppIntentBase.IntentOrder({
            orderId: bytes32(uint256(0xdeadbeef)),
            app: address(0xA11CE),
            intentSelector: bytes4(0x12345678),
            intentParams: abi.encode(uint256(42)),
            submittedBy: submittedBy,
            chainId: block.chainid,
            deadline: block.timestamp + 1000,
            nonce: 0,
            perpetual: false,
            maxExecutions: 1,
            cooldown: 0
        });
    }

    function _sign(uint256 key, IAppIntentBase.IntentOrder memory order)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = harness.digestOf(order);
        (v, r, s) = vm.sign(key, digest);
    }

    // --- EOA: canonical v (27/28) verifies (baseline) ---
    function test_eoa_canonical_v_verifies() public view {
        IAppIntentBase.IntentOrder memory order = _order(user);
        (uint8 v, bytes32 r, bytes32 s) = _sign(userKey, order);
        assertTrue(v == 27 || v == 28);
        assertTrue(harness.verify(order, abi.encodePacked(r, s, v)));
    }

    // --- #229: EOA non-canonical v (0/1) now verifies (was rejected) ---
    function test_eoa_noncanonical_v_now_verifies() public view {
        IAppIntentBase.IntentOrder memory order = _order(user);
        (uint8 v, bytes32 r, bytes32 s) = _sign(userKey, order);
        uint8 v01 = v - 27; // 0 or 1 — the form non-MetaMask signers emit
        assertTrue(harness.verify(order, abi.encodePacked(r, s, v01)));
    }

    function test_eoa_wrong_signer_rejected() public {
        (, uint256 otherKey) = makeAddrAndKey("other");
        IAppIntentBase.IntentOrder memory order = _order(user); // submittedBy = user
        (uint8 v, bytes32 r, bytes32 s) = _sign(otherKey, order); // signed by other
        assertFalse(harness.verify(order, abi.encodePacked(r, s, v)));
    }

    // --- #229: ERC-1271 smart account verifies (was impossible) ---
    function test_erc1271_smart_account_verifies() public {
        MockSmartAccount acct = new MockSmartAccount(user);
        IAppIntentBase.IntentOrder memory order = _order(address(acct));
        // the account's owner EOA signs; the contract validates via ERC-1271
        (uint8 v, bytes32 r, bytes32 s) = _sign(userKey, order);
        assertTrue(harness.verify(order, abi.encodePacked(r, s, v)));
    }

    function test_erc1271_wrong_owner_rejected() public {
        (, uint256 otherKey) = makeAddrAndKey("other");
        MockSmartAccount acct = new MockSmartAccount(user); // owner = user
        IAppIntentBase.IntentOrder memory order = _order(address(acct));
        (uint8 v, bytes32 r, bytes32 s) = _sign(otherKey, order); // signed by other
        assertFalse(harness.verify(order, abi.encodePacked(r, s, v)));
    }
}
