// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.4;

import "../ERC20/TowerERC20.sol";

contract MockChainlinkOracle {
    uint8 public decimals = 8;

    function latestRoundData()
        public pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = 36893488147420167717;
        answer = 100000000;
        startedAt = 1639978317;
        updatedAt = 1639978317;
        answeredInRound = 36893488147420167717;
    }
}
