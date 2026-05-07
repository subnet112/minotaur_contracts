// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./interfaces/IValidatorRegistry.sol";

/// @title ChampionRegistry — on-chain attestation of champion solver certifications
/// @notice Stores certified champion records after verifying EIP-712 quorum from
///         the Bittensor validator set. A GitHub Action reads this contract to
///         auto-merge the champion's solver code — the leader API can only create
///         PRs, not merge directly. This prevents a compromised leader from self-
///         certifying malicious solver code.
///
/// @dev Trust model:
///   1. Validators sign ChampionApproval tuples off-chain (EIP-712)
///   2. The leader calls certify() with the collected signatures
///   3. This contract recovers each signer, checks isValidator() on the
///      ValidatorRegistry, and enforces quorum (N-of-M)
///   4. A GitHub Action watches for ChampionCertified events and auto-merges
///      the corresponding PR only if the on-chain record is valid
///
///   `commitHash`, `nonce`, and `deadline` are part of the EIP-712 signed
///   struct. commitHash means validators explicitly approve a specific git
///   SHA (the GitHub Action re-checks this against the PR head SHA at merge
///   time as belt-and-suspenders). nonce is per-signer monotonic and prevents
///   replay of an unexpired approval against a different roundId. deadline
///   caps the lifetime of any signature.
contract ChampionRegistry {
    using ECDSA for bytes32;

    // ── EIP-712 ─────────────────────────────────────────────────────────────

    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // Must match champion_manager.py CHAMPION_APPROVAL_TYPEHASH EXACTLY.
    // v2 adds commitHash, nonce, deadline to the signed digest:
    //   - commitHash binds the git SHA to the signature (closes the
    //     "leader lies about which commit" gap — the GitHub Action also
    //     checks this at merge time, but signing it means on-chain state
    //     is directly what validators agreed to).
    //   - nonce + deadline are replay protection. nonce must be strictly
    //     greater than the last-seen nonce from the same signer; deadline
    //     is a unix seconds expiry.
    bytes32 public constant CHAMPION_APPROVAL_TYPEHASH = keccak256(
        "ChampionApproval("
        "bytes32 roundId,"
        "bytes32 committeeHash,"
        "bytes32 incumbentImageId,"
        "bytes32 candidateSubmissionId,"
        "bytes32 candidateImageId,"
        "bytes32 benchmarkPackHash,"
        "bytes32 shadowCaseLogHash,"
        "uint256 effectiveEpoch,"
        "bytes32 commitHash,"
        "uint256 nonce,"
        "uint256 deadline"
        ")"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;

    // ── State ───────────────────────────────────────────────────────────────

    IValidatorRegistry public immutable validatorRegistry;
    uint256 public quorumBps;
    address public owner;

    // Per-signer monotonic nonce. A signer's approval is only accepted if
    // its nonce is strictly greater than any previously-seen nonce from the
    // same address. Prevents an old-but-still-unexpired approval from being
    // replayed against a different roundId.
    mapping(address => uint256) public lastNonce;

    struct ChampionRecord {
        bytes32 roundId;
        bytes32 candidateSubmissionId;
        bytes32 candidateImageId;
        bytes32 commitHash;
        uint256 effectiveEpoch;
        uint256 certifiedAt;
        uint256 approvalCount;
        bool exists;
    }

    mapping(bytes32 => ChampionRecord) public champions;
    bytes32 public latestRoundId;
    uint256 public certificationCount;

    // ── Events ──────────────────────────────────────────────────────────────

    event ChampionCertified(
        bytes32 indexed roundId,
        bytes32 indexed candidateSubmissionId,
        bytes32 candidateImageId,
        bytes32 commitHash,
        uint256 effectiveEpoch,
        uint256 approvalCount
    );

    event QuorumBpsUpdated(uint256 newQuorumBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _validatorRegistry,
        uint256 _quorumBps,
        address _owner
    ) {
        require(_validatorRegistry != address(0), "Invalid registry");
        require(_quorumBps > 0 && _quorumBps <= 10000, "Invalid quorum BPS");
        require(_owner != address(0), "Invalid owner");

        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        quorumBps = _quorumBps;
        owner = _owner;

        // Domain separator matches champion_manager.py's build_domain_separator()
        // with name="MinotaurChampionConsensus", version="1"
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            keccak256("MinotaurChampionConsensus"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    // ── Core ────────────────────────────────────────────────────────────────

    /// @notice Record a champion certification with validator quorum proof.
    /// @param roundId Solver round identifier (keccak of string)
    /// @param committeeHash Keccak of sorted validator addresses
    /// @param incumbentImageId Docker image ID of the current champion
    /// @param candidateSubmissionId Submission that won the benchmark
    /// @param candidateImageId Docker image ID of the winning solver
    /// @param benchmarkPackHash Hash of the benchmark inputs
    /// @param shadowCaseLogHash Hash of the test cases used
    /// @param effectiveEpoch Bittensor epoch when this champion activates
    /// @param commitHash Git commit hash (signed — GitHub Action cross-checks
    ///                   against PR head SHA)
    /// @param deadline Unix seconds; block.timestamp must be <= deadline
    /// @param nonces Per-signature nonce. nonces[i] corresponds to signatures[i].
    ///               Each must be strictly greater than lastNonce[signer].
    /// @param signatures EIP-712 signatures sorted by recovered signer ascending
    function certify(
        bytes32 roundId,
        bytes32 committeeHash,
        bytes32 incumbentImageId,
        bytes32 candidateSubmissionId,
        bytes32 candidateImageId,
        bytes32 benchmarkPackHash,
        bytes32 shadowCaseLogHash,
        uint256 effectiveEpoch,
        bytes32 commitHash,
        uint256 deadline,
        uint256[] calldata nonces,
        bytes[] calldata signatures
    ) external {
        require(!champions[roundId].exists, "Already certified");
        require(signatures.length > 0, "No signatures");
        require(nonces.length == signatures.length, "nonces/sigs length mismatch");
        require(block.timestamp <= deadline, "Expired");

        // Recover signers and verify each is a registered validator.
        // Signatures must be sorted by signer address ascending (prevents duplicates).
        // Each signature is over the EIP-712 digest that includes its own
        // nonce — so two signers can pass different nonces in the same call.
        uint256 validCount = 0;
        address lastSigner = address(0);

        for (uint256 i = 0; i < signatures.length; i++) {
            bytes32 structHash = keccak256(abi.encode(
                CHAMPION_APPROVAL_TYPEHASH,
                roundId,
                committeeHash,
                incumbentImageId,
                candidateSubmissionId,
                candidateImageId,
                benchmarkPackHash,
                shadowCaseLogHash,
                effectiveEpoch,
                commitHash,
                nonces[i],
                deadline
            ));
            bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);

            address signer = digest.recover(signatures[i]);

            // Ascending order enforced — no duplicate signers
            require(signer > lastSigner, "Signatures not sorted or duplicate");
            lastSigner = signer;

            // Reject stale signatures: nonce must be strictly greater than the
            // last one this signer used on this registry.
            require(nonces[i] > lastNonce[signer], "Nonce not increasing");
            lastNonce[signer] = nonces[i];

            if (validatorRegistry.isValidator(signer)) {
                validCount++;
            }
        }

        // Enforce quorum
        uint256 totalValidators = validatorRegistry.getValidatorCount();
        uint256 required = (totalValidators * quorumBps + 9999) / 10000;
        if (required == 0) required = 1;
        require(validCount >= required, "Quorum not reached");

        // Store the certification record
        champions[roundId] = ChampionRecord({
            roundId: roundId,
            candidateSubmissionId: candidateSubmissionId,
            candidateImageId: candidateImageId,
            commitHash: commitHash,
            effectiveEpoch: effectiveEpoch,
            certifiedAt: block.timestamp,
            approvalCount: validCount,
            exists: true
        });
        latestRoundId = roundId;
        certificationCount++;

        emit ChampionCertified(
            roundId,
            candidateSubmissionId,
            candidateImageId,
            commitHash,
            effectiveEpoch,
            validCount
        );
    }

    // ── Views ───────────────────────────────────────────────────────────────

    function getChampion(bytes32 roundId) external view returns (ChampionRecord memory) {
        return champions[roundId];
    }

    function isChampionCertified(bytes32 roundId) external view returns (bool) {
        return champions[roundId].exists;
    }

    function getLatestChampion() external view returns (ChampionRecord memory) {
        return champions[latestRoundId];
    }

    function getQuorumRequired() external view returns (uint256) {
        uint256 n = validatorRegistry.getValidatorCount();
        uint256 required = (n * quorumBps + 9999) / 10000;
        return required == 0 ? 1 : required;
    }

    // ── Admin ───────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function setQuorumBps(uint256 _quorumBps) external onlyOwner {
        require(_quorumBps > 0 && _quorumBps <= 10000, "Invalid quorum BPS");
        quorumBps = _quorumBps;
        emit QuorumBpsUpdated(_quorumBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
