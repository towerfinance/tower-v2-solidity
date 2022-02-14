// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract TowerProtocol is Ownable, ReentrancyGuard {
    uint256 internal constant RATIO_PRECISION = 1e6;
    uint256 internal constant PRICE_PRECISION = 1e6;
    uint256 internal constant USDC_PRECISION = 1e6;
    uint256 internal constant MISSING_PRECISION = 1e12;
    uint256 internal constant TOWER_PRECISION = 1e18;
    uint256 internal constant CUBE_PRECISION = 1e18;
    uint256 internal constant SWAP_FEE_PRECISION = 1e4;

    address internal constant ADDRESS_USDC =
        0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address internal constant ADDRESS_WMATIC =
        0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    address public operator;

    event OperatorUpdated(address indexed newOperator);

    constructor() {
        setOperator(msg.sender);
    }

    modifier onlyNonContract() {
        require(msg.sender == tx.origin, "Tower: sender != origin");
        _;
    }

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || msg.sender == operator,
            "Tower: sender != operator"
        );
        _;
    }

    function setOperator(address _operator) public onlyOwner {
        require(_operator != address(0), "Tower: Invalid operator");
        operator = _operator;
        emit OperatorUpdated(operator);
    }

    function _currentBlockTs() internal view returns (uint64) {
        return SafeCast.toUint64(block.timestamp);
    }
}
