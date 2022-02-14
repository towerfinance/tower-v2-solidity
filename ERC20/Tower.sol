// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./TowerERC20.sol";

contract Tower is TowerERC20 {
    uint256 public constant GENESIS_SUPPLY = 100 ether;

    constructor(address _bank) TowerERC20("Tower USD", "TWR", _bank) {
        _mint(msg.sender, GENESIS_SUPPLY);
    }

    function mintByFarm(address _to, uint256 _amt) public override onlyFarm {
        require(false, "Farm can't mint");
        emit LogMint(_to, _amt);
    }
}
