// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Test double for Bittensor's staking precompile at 0x…0805.
///
/// Faithful about the two things that matter and honest about the one it can't be:
///
///   * CUSTODY: `addStake` credits the mapped coldkey of `msg.sender`, never a
///     caller-supplied one. Tests wire the mapping with `setColdkeyFor` because
///     blake2_256 is unavailable on chain 964 (no blake2f precompile at 0x09) —
///     the chain derives it, we inject it. See test/Blake2Coldkey.t.sol.
///   * UNITS: `amountRao` is 9-decimal; native value is 18-decimal. The mock
///     debits `amountRao * 1e9` wei, exactly as the fork was measured to do.
///
/// NOT faithful about price: `alphaPerRao` is a settable constant, where the real
/// thing clears through the subnet AMM. So a mock test can prove share ARITHMETIC
/// and never proves anything about slippage. That belongs on the fork.
contract MockStakingV2 {
    uint256 public constant WEI_PER_RAO = 1e9;

    mapping(address => bytes32) public coldkeyOf;
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public stake;

    uint256 public alphaPerRao = 445;      // ~ the fork's observed 1 TAO -> 445.8e9 alpha
    uint256 public exitFeeBps = 10;        // ~ the fork's measured 10.1 bps round trip

    function setColdkeyFor(address who, bytes32 ck) external { coldkeyOf[who] = ck; }
    function setAlphaPerRao(uint256 r) external { alphaPerRao = r; }
    function setExitFeeBps(uint256 b) external { exitFeeBps = b; }

    /// Emission, or a hostile donation via `transferStake` — both look like this.
    function creditAlpha(bytes32 ck, bytes32 hk, uint256 nid, uint256 amount) external {
        stake[ck][hk][nid] += amount;
    }

    /// A drawdown: alpha lost to slashing or to the pool moving against us.
    function debitAlpha(bytes32 ck, bytes32 hk, uint256 nid, uint256 amount) external {
        stake[ck][hk][nid] -= amount;
    }

    function getStake(bytes32 hk, bytes32 ck, uint256 nid) external view returns (uint256) {
        return stake[ck][hk][nid];
    }

    function addStake(bytes32 hk, uint256 amountRao, uint256 nid) external payable {
        // the precompile debits the caller's native balance itself
        uint256 cost = amountRao * WEI_PER_RAO;
        require(msg.sender.balance + msg.value >= cost, "insufficient");
        stake[coldkeyOf[msg.sender]][hk][nid] += amountRao * alphaPerRao;
    }

    function removeStake(bytes32 hk, uint256 amountAlpha, uint256 nid) external payable {
        bytes32 ck = coldkeyOf[msg.sender];
        require(stake[ck][hk][nid] >= amountAlpha, "exceeds stake");
        stake[ck][hk][nid] -= amountAlpha;
        uint256 rao = amountAlpha / alphaPerRao;
        uint256 wei_ = rao * WEI_PER_RAO;
        wei_ -= (wei_ * exitFeeBps) / 10_000;
        (bool ok,) = msg.sender.call{value: wei_}("");
        require(ok, "payout failed");
    }

    function removeStakeLimit(bytes32 hk, uint256 a, uint256, bool, uint256 nid) external payable {
        this.removeStake{value: 0}(hk, a, nid);
    }

    function transferStake(bytes32 dstCk, bytes32 hk, uint256 srcNid, uint256 dstNid, uint256 amount)
        external payable
    {
        bytes32 ck = coldkeyOf[msg.sender];
        require(stake[ck][hk][srcNid] >= amount, "exceeds stake");
        stake[ck][hk][srcNid] -= amount;
        stake[dstCk][hk][dstNid] += amount;
    }

    /// Same-netuid moves are lossless on the real chain (fork-measured, 0.0000%),
    /// so the mock is faithful here. `moveLossBps` exists so a test can prove the
    /// vault REVERTS on a lossy move rather than silently repricing shares.
    uint256 public moveLossBps;
    function setMoveLossBps(uint256 b) external { moveLossBps = b; }

    /// The real extrinsic arrives exactly ONE rao short — integer rounding, and
    /// fork-measured identical at 1 TAO and 25 TAO. Absolute, not proportional.
    uint256 public moveDust;
    function setMoveDust(uint256 d) external { moveDust = d; }

    function moveStake(bytes32 fromHk, bytes32 toHk, uint256 srcNid, uint256 dstNid, uint256 amount)
        external payable
    {
        bytes32 ck = coldkeyOf[msg.sender];
        require(stake[ck][fromHk][srcNid] >= amount, "exceeds stake");
        stake[ck][fromHk][srcNid] -= amount;
        stake[ck][toHk][dstNid] += amount - (amount * moveLossBps) / 10_000 - moveDust;
    }

    receive() external payable {}
}
