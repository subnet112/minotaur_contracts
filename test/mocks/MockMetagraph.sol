// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Test double for Bittensor's metagraph precompile at 0x…0802.
///
/// Faithful in shape and in the one property the scorer depends on: dividends is
/// a NORMALISED share of the subnet's emission (u16, summing to ~65535 across all
/// uids), not a rate — so a per-delegator return is `dividends / stake`, and a
/// large validator with a large dividend share can still be the worse choice.
/// Defaults mirror SN112 at fork block 8892914, where 10 of 256 uids earned and
/// uid 0 held 53111/65530 of the dividends on 672,893,522,735 alpha.
///
/// It cannot model delegate TAKE, for the honest reason that the real precompile
/// does not expose it either. Nothing that reads this can price take.
contract MockMetagraph {
    mapping(uint16 => uint16) public uidCount;
    mapping(uint16 => mapping(uint16 => bytes32)) public hotkeys;
    mapping(uint16 => mapping(uint16 => uint64)) public stakes;
    mapping(uint16 => mapping(uint16 => uint16)) public dividends;
    mapping(uint16 => mapping(uint16 => uint64)) public emissions;
    mapping(uint16 => mapping(uint16 => bool)) public validator;

    function setNeuron(uint16 netuid, uint16 uid, bytes32 hotkey, uint64 stake, uint16 div, bool isVali)
        external
    {
        hotkeys[netuid][uid] = hotkey;
        stakes[netuid][uid] = stake;
        dividends[netuid][uid] = div;
        validator[netuid][uid] = isVali;
        if (uid + 1 > uidCount[netuid]) uidCount[netuid] = uid + 1;
    }

    function getUidCount(uint16 n) external view returns (uint16) { return uidCount[n]; }
    function getHotkey(uint16 n, uint16 u) external view returns (bytes32) { return hotkeys[n][u]; }
    function getStake(uint16 n, uint16 u) external view returns (uint64) { return stakes[n][u]; }
    function getDividends(uint16 n, uint16 u) external view returns (uint16) { return dividends[n][u]; }
    function getEmission(uint16 n, uint16 u) external view returns (uint64) { return emissions[n][u]; }
    function getIncentive(uint16, uint16) external pure returns (uint16) { return 0; }
    function getConsensus(uint16, uint16) external pure returns (uint16) { return 0; }
    function getVtrust(uint16, uint16) external pure returns (uint16) { return 0; }
    function getValidatorStatus(uint16 n, uint16 u) external view returns (bool) { return validator[n][u]; }
}
