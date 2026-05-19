// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ChampionRegistry.sol";
import "../src/ValidatorRegistry.sol";

contract ChampionRegistryTest is Test {
    ChampionRegistry public registry;
    ValidatorRegistry public validatorReg;

    address public owner;
    uint256 public ownerKey;
    address[] public validatorAddrs;
    uint256[] public validatorKeys;

    bytes32 public DOMAIN_SEPARATOR;

    function setUp() public {
        (owner, ownerKey) = makeAddrAndKey("owner");

        // Create 3 validators
        for (uint256 i = 0; i < 3; i++) {
            (address addr, uint256 key) = makeAddrAndKey(
                string(abi.encodePacked("validator", vm.toString(i)))
            );
            validatorAddrs.push(addr);
            validatorKeys.push(key);
        }

        // Sort validators by address (required for signature verification)
        _sortValidators();

        // Deploy ValidatorRegistry (also holds quorum, but ChampionRegistry keeps
        // its own quorum knob — see refactor/single-quorum-source out-of-scope note).
        validatorReg = new ValidatorRegistry(owner, validatorAddrs, 6666);
        registry = new ChampionRegistry(
            address(validatorReg),
            6666,   // quorumBps: 2-of-3 (ChampionRegistry's own field)
            owner
        );

        DOMAIN_SEPARATOR = registry.DOMAIN_SEPARATOR();
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    function _sortValidators() internal {
        // Bubble sort by address ascending
        for (uint256 i = 0; i < validatorAddrs.length; i++) {
            for (uint256 j = i + 1; j < validatorAddrs.length; j++) {
                if (validatorAddrs[i] > validatorAddrs[j]) {
                    (validatorAddrs[i], validatorAddrs[j]) = (validatorAddrs[j], validatorAddrs[i]);
                    (validatorKeys[i], validatorKeys[j]) = (validatorKeys[j], validatorKeys[i]);
                }
            }
        }
    }

    struct _ProposalArgs {
        bytes32 roundId;
        bytes32 committeeHash;
        bytes32 incumbentImageId;
        bytes32 candidateSubmissionId;
        bytes32 candidateImageId;
        bytes32 benchmarkPackHash;
        bytes32 shadowCaseLogHash;
        uint256 effectiveEpoch;
        bytes32 commitHash;
        uint256 deadline;
    }

    function _buildProposalDigest(
        _ProposalArgs memory p,
        uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            registry.CHAMPION_APPROVAL_TYPEHASH(),
            p.roundId,
            p.committeeHash,
            p.incumbentImageId,
            p.candidateSubmissionId,
            p.candidateImageId,
            p.benchmarkPackHash,
            p.shadowCaseLogHash,
            p.effectiveEpoch,
            p.commitHash,
            nonce,
            p.deadline
        ));
        return MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
    }

    /// Produce N sigs (one per validator, in index order), with monotonically
    /// increasing per-signer nonces starting at `baseNonce + 1` for signer[i].
    function _signAll(
        _ProposalArgs memory p,
        uint256 count,
        uint256 baseNonce
    ) internal view returns (bytes[] memory sigs, uint256[] memory nonces) {
        sigs = new bytes[](count);
        nonces = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            nonces[i] = baseNonce + i + 1;
            bytes32 digest = _buildProposalDigest(p, nonces[i]);
            sigs[i] = _signDigest(digest, validatorKeys[i]);
        }
    }

    function _certify(
        _ProposalArgs memory p,
        bytes[] memory sigs,
        uint256[] memory nonces
    ) internal {
        registry.certify(
            p.roundId,
            p.committeeHash,
            p.incumbentImageId,
            p.candidateSubmissionId,
            p.candidateImageId,
            p.benchmarkPackHash,
            p.shadowCaseLogHash,
            p.effectiveEpoch,
            p.commitHash,
            p.deadline,
            nonces,
            sigs
        );
    }

    function _signDigest(bytes32 digest, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultProposalArgs() internal view returns (_ProposalArgs memory p) {
        p.roundId = keccak256("round-e42-n1");
        p.committeeHash = keccak256("committee");
        p.incumbentImageId = keccak256("sha256:oldchamp");
        p.candidateSubmissionId = keccak256("sub_abc123");
        p.candidateImageId = keccak256("sha256:newchamp");
        p.benchmarkPackHash = keccak256("benchpack");
        p.shadowCaseLogHash = keccak256("shadowlog");
        p.effectiveEpoch = 42;
        p.commitHash = keccak256("abc123def456");
        p.deadline = block.timestamp + 3600;
    }

    // ── Tests ───────────────────────────────────────────────────────────────

    function test_certify_withQuorum() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        (bytes[] memory sigs, uint256[] memory nonces) = _signAll(p, 3, 0);
        _certify(p, sigs, nonces);

        assertTrue(registry.isChampionCertified(p.roundId));
        ChampionRegistry.ChampionRecord memory record = registry.getChampion(p.roundId);
        assertEq(record.roundId, p.roundId);
        assertEq(record.candidateSubmissionId, p.candidateSubmissionId);
        assertEq(record.commitHash, p.commitHash);
        assertEq(record.effectiveEpoch, p.effectiveEpoch);
        assertEq(record.approvalCount, 3);
        assertTrue(record.exists);

        assertEq(registry.latestRoundId(), p.roundId);
        assertEq(registry.certificationCount(), 1);

        // Per-signer nonces recorded.
        for (uint256 i = 0; i < 3; i++) {
            assertEq(registry.lastNonce(validatorAddrs[i]), nonces[i]);
        }
    }

    function test_certify_withMinQuorum() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        (bytes[] memory sigs, uint256[] memory nonces) = _signAll(p, 2, 0);
        _certify(p, sigs, nonces);

        ChampionRegistry.ChampionRecord memory record = registry.getChampion(p.roundId);
        assertEq(record.approvalCount, 2);
        assertTrue(record.exists);
    }

    function test_certify_belowQuorum_reverts() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        (bytes[] memory sigs, uint256[] memory nonces) = _signAll(p, 1, 0);

        vm.expectRevert(bytes("Quorum not reached"));
        _certify(p, sigs, nonces);
    }

    function test_certify_duplicateRound_reverts() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        (bytes[] memory sigs, uint256[] memory nonces) = _signAll(p, 3, 0);
        _certify(p, sigs, nonces);

        // Re-certify with strictly-greater nonces still reverts on roundId.
        (bytes[] memory sigs2, uint256[] memory nonces2) = _signAll(p, 3, 100);
        vm.expectRevert(bytes("Already certified"));
        _certify(p, sigs2, nonces2);
    }

    function test_certify_unsortedSigs_reverts() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        // Sign each with its own nonce matching the one in the digest.
        uint256 n0 = 10;
        uint256 n1 = 11;
        bytes32 d0 = _buildProposalDigest(p, n0);
        bytes32 d1 = _buildProposalDigest(p, n1);
        bytes[] memory sigs = new bytes[](2);
        uint256[] memory nonces = new uint256[](2);
        sigs[0] = _signDigest(d1, validatorKeys[1]); // higher address first
        nonces[0] = n1;
        sigs[1] = _signDigest(d0, validatorKeys[0]); // lower address second
        nonces[1] = n0;

        vm.expectRevert(bytes("Signatures not sorted or duplicate"));
        _certify(p, sigs, nonces);
    }

    function test_certify_nonValidatorSig_doesNotCount() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        (, uint256 randomKey) = makeAddrAndKey("random");
        address randomAddr = vm.addr(randomKey);

        // Sign a valid + random pair, each with its own nonce.
        uint256 nValid = 10;
        uint256 nRandom = 11;
        bytes32 dValid = _buildProposalDigest(p, nValid);
        bytes32 dRandom = _buildProposalDigest(p, nRandom);
        bytes memory validSig = _signDigest(dValid, validatorKeys[0]);
        bytes memory randomSig = _signDigest(dRandom, randomKey);

        address validAddr = validatorAddrs[0];
        bytes[] memory sigs = new bytes[](2);
        uint256[] memory nonces = new uint256[](2);
        if (validAddr < randomAddr) {
            sigs[0] = validSig;  nonces[0] = nValid;
            sigs[1] = randomSig; nonces[1] = nRandom;
        } else {
            sigs[0] = randomSig; nonces[0] = nRandom;
            sigs[1] = validSig;  nonces[1] = nValid;
        }

        vm.expectRevert(bytes("Quorum not reached"));
        _certify(p, sigs, nonces);
    }

    function test_certify_emitsEvent() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        (bytes[] memory sigs, uint256[] memory nonces) = _signAll(p, 3, 0);

        vm.expectEmit(true, true, false, true);
        emit ChampionRegistry.ChampionCertified(
            p.roundId, p.candidateSubmissionId, p.candidateImageId,
            p.commitHash, p.effectiveEpoch, 3
        );
        _certify(p, sigs, nonces);
    }

    function test_getQuorumRequired() public view {
        // 6666 bps of 3 validators = ceil(3 * 6666 / 10000) = ceil(1.9998) = 2
        assertEq(registry.getQuorumRequired(), 2);
    }

    function test_getLatestChampion() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        (bytes[] memory sigs, uint256[] memory nonces) = _signAll(p, 3, 0);
        _certify(p, sigs, nonces);

        ChampionRegistry.ChampionRecord memory latest = registry.getLatestChampion();
        assertEq(latest.roundId, p.roundId);
        assertEq(latest.commitHash, p.commitHash);
    }

    // ── New v2 tests: nonce + deadline ─────────────────────────────────────

    function test_certify_expired_reverts() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        p.deadline = block.timestamp; // exactly now is ok; go one before
        p.deadline = p.deadline - 1;
        (bytes[] memory sigs, uint256[] memory nonces) = _signAll(p, 3, 0);

        vm.expectRevert(bytes("Expired"));
        _certify(p, sigs, nonces);
    }

    function test_certify_replayed_nonce_reverts() public {
        // First cert: nonces 1,2,3 for signers 0,1,2.
        _ProposalArgs memory p1 = _defaultProposalArgs();
        (bytes[] memory sigs1, uint256[] memory nonces1) = _signAll(p1, 3, 0);
        _certify(p1, sigs1, nonces1);

        // Second cert with DIFFERENT roundId but re-using the same nonces.
        _ProposalArgs memory p2 = _defaultProposalArgs();
        p2.roundId = keccak256("round-e42-n2");
        (bytes[] memory sigs2, uint256[] memory nonces2) = _signAll(p2, 3, 0);

        vm.expectRevert(bytes("Nonce not increasing"));
        _certify(p2, sigs2, nonces2);
    }

    function test_certify_second_round_with_increasing_nonces_succeeds() public {
        _ProposalArgs memory p1 = _defaultProposalArgs();
        (bytes[] memory sigs1, uint256[] memory nonces1) = _signAll(p1, 3, 0);
        _certify(p1, sigs1, nonces1);

        _ProposalArgs memory p2 = _defaultProposalArgs();
        p2.roundId = keccak256("round-e42-n2");
        // Base nonce 100 → each signer uses 101/102/103, strictly greater
        // than the 1/2/3 they used last round.
        (bytes[] memory sigs2, uint256[] memory nonces2) = _signAll(p2, 3, 100);
        _certify(p2, sigs2, nonces2);

        assertTrue(registry.isChampionCertified(p2.roundId));
        for (uint256 i = 0; i < 3; i++) {
            assertEq(registry.lastNonce(validatorAddrs[i]), nonces2[i]);
        }
    }

    function test_certify_nonces_length_mismatch_reverts() public {
        _ProposalArgs memory p = _defaultProposalArgs();
        (bytes[] memory sigs, ) = _signAll(p, 3, 0);
        uint256[] memory nonces = new uint256[](2); // wrong length

        vm.expectRevert(bytes("nonces/sigs length mismatch"));
        _certify(p, sigs, nonces);
    }

    function test_setQuorumBps_onlyOwner() public {
        vm.prank(owner);
        registry.setQuorumBps(8000);
        assertEq(registry.quorumBps(), 8000);

        vm.prank(address(0xdead));
        vm.expectRevert(bytes("Not owner"));
        registry.setQuorumBps(5000);
    }

    function test_domainSeparator_matchesExpected() public view {
        // Reconstruct the domain separator manually to verify correctness
        bytes32 expected = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("MinotaurChampionConsensus"),
            keccak256("1"),
            block.chainid,
            address(registry)
        ));
        assertEq(registry.DOMAIN_SEPARATOR(), expected);
    }
}
