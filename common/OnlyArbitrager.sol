// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract OnlyArbitrager is Ownable {
    address public arbitrager;

    event LogSetArbitrager(address indexed arbitrager);

    modifier onlyArb() {
        require(msg.sender == arbitrager, "OnlyArbitrager: sender != arb");
        _;
    }

    function setArbitrager(address _arbitrager) public onlyOwner {
        arbitrager = _arbitrager;
        emit LogSetArbitrager(arbitrager);
    }
}
