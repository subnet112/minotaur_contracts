// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

/// Can a contract derive its OWN Bittensor coldkey on chain?
///
/// ON A STANDARD EVM, YES — and this test proves it. AlphaVault once justified
/// its coldkey constructor argument by saying the EVM "offers only blake2f, the
/// compression function, not the full hash". That reasoning is wrong: full
/// BLAKE2b is nothing more than seeding h from the IV with the digest length
/// mixed in, calling F once per 128-byte block, and taking the first `outlen`
/// bytes. "evm:" + a 20-byte address is 24 bytes — ONE block — so the whole hash
/// is a single staticcall, in 5,594 gas, matching four coldkeys read off a live
/// Finney fork.
///
/// THE REAL OBSTACLE IS CHAIN 964, NOT THE EVM. That chain does not provide
/// blake2f: address 0x09 answers the EIP-152 test vector with an elliptic-curve
/// error ("Invalid point y coordinate") while sha256 at 0x02 works normally,
/// probed on a fork at block 8901111. So the constructor argument stays — but
/// this test is kept as the record of WHY, and as the thing to delete the
/// argument by if 0x09 is ever enabled.
library Blake2 {
    /// IV with h[0] ^= 0x01010000 ^ (keylen << 8) ^ outlen, keylen=0 outlen=32,
    /// serialised as the precompile wants it: 8 LITTLE-endian 64-bit words.
    bytes constant H0 =
        hex"28c9bdf267e6096a"
        hex"3ba7ca8485ae67bb"
        hex"2bf894fe72f36e3c"
        hex"f1361d5f3af54fa5"
        hex"d182e6ad7f520e51"
        hex"1f6c3e2b8c68059b"
        hex"6bbd41fbabd9831f"
        hex"79217e1319cde05b";

    /// blake2_256("evm:" | addr) — the HashedAddressMapping the runtime uses to
    /// decide which substrate account an EVM address controls.
    function coldkeyOf(address a) internal view returns (bytes32 out) {
        bytes memory m = new bytes(128); // zero-padded single block
        m[0] = "e"; m[1] = "v"; m[2] = "m"; m[3] = ":";
        bytes20 b = bytes20(a);
        for (uint256 i = 0; i < 20; ++i) m[4 + i] = b[i];

        bytes memory input = abi.encodePacked(
            uint32(12),                     // rounds, BIG endian
            H0,                             // h
            m,                              // message block
            bytes8(hex"1800000000000000"),  // t0 = 24, LITTLE endian
            bytes8(0),                      // t1
            uint8(1)                        // final block
        );
        require(input.length == 213, "bad blake2f input");

        bool ok;
        bytes memory ret = new bytes(64);
        assembly {
            ok := staticcall(gas(), 0x09, add(input, 32), 213, add(ret, 32), 64)
        }
        require(ok, "blake2f unavailable");
        assembly { out := mload(add(ret, 32)) } // first 32 bytes of the state
    }
}

contract Blake2ColdkeyTest is Test {
    // Ground truth: pairs read off a live Finney fork via the runtime's own
    // mapping, cross-checked against the polkadot util-crypto reference.
    function test_it_matches_the_runtimes_own_mapping() public view {
        assertEq(
            Blake2.coldkeyOf(0x0000000000000000000000000000000000009980),
            bytes32(0x759e4040f4191fd888ad3869de79d3467376d4c9d37405f7e05d961fe9bc1109),
            "vault coldkey"
        );
        assertEq(
            Blake2.coldkeyOf(0x0000000000000000000000000000000000009970),
            bytes32(0xb4e4521d98cd3fe95c67265d136c2222da0479a2f4bf3eaf0845c84e34b6ec2f),
            "second vault coldkey"
        );
        assertEq(
            Blake2.coldkeyOf(0x0000000000000000000000000000000000009962),
            bytes32(0xd32bbfac4d004138ceed2b14f239da6dab3b71219b58ca7b7f597d57cf3f8f72),
            "witness coldkey"
        );
        // mixed-case, non-trivial address
        assertEq(
            Blake2.coldkeyOf(0x7dC30109A32764f808823095C576A0355b7978d6),
            bytes32(0x9d40b3e89cec446b8c915263a455b56aff99041f3a18add1e36431c1ec290679),
            "registry owner coldkey"
        );
    }

    function test_gas() public view {
        uint256 g = gasleft();
        Blake2.coldkeyOf(address(this));
        console.log("coldkeyOf gas:", g - gasleft());
    }
}
