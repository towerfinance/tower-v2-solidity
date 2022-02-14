// SPDX-License-Identifier: UNLICENSE

pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20("MockERC20", "Mock"), Ownable {
    uint256 public constant TOTAL_SUPPLY = 1000000e18;

    // @notice Must only be called by anyone! haha!
    function mint(address _to, uint256 _amount) public {
        require(_to != address(0));
        require(_amount > 0);
        _mint(_to, _amount);
    }

    function setBalance(address _to, uint256 _amount) public {
        _burn(_to, balanceOf(_to));
        _mint(_to, _amount);
    }
}
