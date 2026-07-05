// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║              pSunDAI_ASA Token — v9                              ║
 * ║   Immutable vault-linked ERC20 for the pSunDAI CDP system        ║
 * ║   No changes from v7 — token logic was already correct.          ║
 * ║   Dev: ELITE TEAM6 | https://www.sundaitoken.com                 ║
 * ╚══════════════════════════════════════════════════════════════════╝
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract pSunDAI_ASA is ERC20 {

    string public constant VERSION = "pSunDAI_ASA_v9";

    address public vault;
    address public immutable deployer;
    bool    public vaultSet;

    modifier onlyVault() {
        require(msg.sender == vault && vault != address(0), "Not vault");
        _;
    }

    constructor() ERC20("SunDAI Autonomous Stable Asset", "pSunDAI") {
        deployer = msg.sender;
    }

    function setVault(address _vault) external {
        require(!vaultSet, "Vault already set");
        require(msg.sender == deployer, "Only deployer");
        require(_vault != address(0), "Invalid vault");
        vault    = _vault;
        vaultSet = true;
        emit VaultLinked(_vault, msg.sender);
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
        emit Minted(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
        emit Burned(from, amount);
    }

    function decimals() public pure override returns (uint8) { return 18; }

    event VaultLinked(address indexed vault, address indexed by);
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
}
