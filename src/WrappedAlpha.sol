// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// The ERC-20 face of one subnet's wrapped alpha position (wAlpha112, …).
///
/// Deliberately dumb: it holds no alpha, prices nothing, and has no logic. All
/// stake, accounting and redemption live in the vault that deployed it, which is
/// the only address allowed to mint or burn. One of these exists per netuid.
///
/// It is a separate contract rather than an ERC-1155 id because the whole point
/// is to be an ordinary ERC-20 — bridgeable, poolable on an AMM, and deliverable
/// by the DEX aggregator as a plain token transfer to a recipient. ERC-1155 ids
/// are none of those things to the rest of DeFi.
contract WrappedAlpha is ERC20 {
    address public immutable vault;
    uint256 public immutable netuid;

    error OnlyVault();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(uint256 _netuid, string memory n, string memory s) ERC20(n, s) {
        vault = msg.sender;
        netuid = _netuid;
    }

    function mint(address to, uint256 amount) external onlyVault { _mint(to, amount); }
    function burn(address from, uint256 amount) external onlyVault { _burn(from, amount); }
}
