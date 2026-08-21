// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Bittensor's metagraph precompile (chain 964), at 0x…0802.
///
/// This is what makes yield optimisation SCORABLE on Minotaur at all. The
/// subnet's harness scores a solver by simulating its plan on a fork and reading
/// the result at a block — but staking yield is a forward-looking rate that
/// normally takes an epoch to observe. Because dividends and stake are ordinary
/// chain state readable here, a re-delegation plan can be judged deterministically
/// at simulation time, with no oracle and no waiting.
///
/// Verified live against a Finney fork at block 8892914: all getters below
/// responded for netuid 112, and `getUidCount` returned 256.
///
/// WHAT IS MISSING AND WHY IT MATTERS: there is NO getter for a validator's
/// delegate TAKE. A delegator earns `dividends × (1 − take)`, so take is
/// first-order — and a plan could route to a high-dividend validator that keeps
/// everything, scoring well on the readable half of the formula while delivering
/// the holder nothing. Ten selector shapes were probed across five precompiles;
/// none exists. The vault answers this with an allowlist (take is vetted once,
/// off-chain, before a hotkey becomes eligible) and with a performance fee paid
/// on REALISED share-price growth rather than on the predicted rate.
interface IMetagraph {
    function getUidCount(uint16 netuid) external view returns (uint16);

    function getHotkey(uint16 netuid, uint16 uid) external view returns (bytes32);

    /// Total alpha delegated to this uid, 9-decimal.
    function getStake(uint16 netuid, uint16 uid) external view returns (uint64);

    /// Yuma-consensus dividend share, normalised across the subnet to u16 —
    /// on SN112 at block 8892914 exactly 10 of 256 uids held a non-zero value
    /// and they summed to 65530, so this is a fraction of the whole, not a rate.
    function getDividends(uint16 netuid, uint16 uid) external view returns (uint16);

    function getEmission(uint16 netuid, uint16 uid) external view returns (uint64);

    function getIncentive(uint16 netuid, uint16 uid) external view returns (uint16);

    function getConsensus(uint16 netuid, uint16 uid) external view returns (uint16);

    function getVtrust(uint16 netuid, uint16 uid) external view returns (uint16);

    function getValidatorStatus(uint16 netuid, uint16 uid) external view returns (bool);
}
