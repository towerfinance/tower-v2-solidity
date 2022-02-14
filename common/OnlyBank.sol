// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract OnlyBank is Ownable {
    address public bank;

    event BankUpdated(address indexed bank);

    modifier onlyBank() {
        require(msg.sender == bank, "OnlyBank: onlyBank");
        _;
    }

    modifier onlyBankOrOwner() {
        require(
            msg.sender == bank || msg.sender == owner(),
            "OnlyBank: onlyBankOrOwner"
        );
        _;
    }

    constructor(address _bank) {
        setBank(_bank);
    }

    function setBank(address _bank) public onlyOwner {
        require(_bank != address(0), "OnlyBank: invalid address");
        bank = _bank;
        emit BankUpdated(bank);
    }
}
