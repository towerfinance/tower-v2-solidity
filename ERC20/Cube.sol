// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./TowerERC20.sol";

contract Cube is TowerERC20 {
    uint256 public constant GENESIS_SUPPLY = 1_000_000 ether; // minted at genesis for liquidity pool seeding

    uint256 public constant COMMUNITY_REWARD_ALLOCATION = 700_000_000 ether;
    uint256 public constant TEAM_FUND_ALLOCATION = 275_000_000 ether;
    uint256 public constant V1_REWARD_AMT = 25_000_000 ether;
    uint256 public constant TEAM_FUND_VESTING_DURATION = 1095 days; // 3 years
    uint256 public constant TEAM_FUND_EMISSION_RATE =
        TEAM_FUND_ALLOCATION / TEAM_FUND_VESTING_DURATION;
    uint256 private constant ONE_YEAR = 365 days;
    uint256 public constant VESTING_DECREASING_RATIO = 290988; // 29.0988%

    uint256 private constant RATIO_PRECISION = 1e6;

    uint256 public cubeMintedByFarm;

    address public treasury;
    address public team;

    struct TeamVesting {
        uint256 startTime;
        uint256 vestedAmount;
        uint256 lastClaimed;
    }
    TeamVesting public teamVesting;

    event TreasuryUpdated(address treasury);
    event SetTeam(address team);

    constructor(
        address _bank,
        uint256 _vestingStartTime,
        address _team,
        address _treasury
    ) TowerERC20("Cube Token", "CUBE", _bank) {
        _mint(msg.sender, GENESIS_SUPPLY + V1_REWARD_AMT);
        _setTeamVesting(_vestingStartTime);
        team = _team;
        setTreasury(_treasury);
    }

    function mintByFarm(address _to, uint256 _amt) public override onlyFarm {
        require(_amt > 0, "Cube: Aero amount");
        require(_to != address(0), "Cube: Zero address");
        require(
            cubeMintedByFarm < COMMUNITY_REWARD_ALLOCATION,
            "Cube: Reward alloc zero"
        );

        if (cubeMintedByFarm + _amt > COMMUNITY_REWARD_ALLOCATION) {
            uint256 amtLeft = COMMUNITY_REWARD_ALLOCATION - cubeMintedByFarm;
            cubeMintedByFarm += amtLeft;
            _mint(_to, amtLeft);
        } else {
            cubeMintedByFarm += _amt;
            _mint(_to, _amt);
        }

        emit LogMint(_to, _amt);
    }

    function _setTeamVesting(uint256 _vestingStartTime) internal {
        teamVesting.startTime = _vestingStartTime;
        teamVesting.lastClaimed = _vestingStartTime;
    }

    function unclaimedTeamFund() public view returns (uint256) {
        uint256 _now = block.timestamp;
        if (_now <= teamVesting.lastClaimed) {
            return 0;
        }

        uint256 _fromEpoch = _now - teamVesting.startTime;
        uint256 _years = _fromEpoch / ONE_YEAR;

        uint256 _emissionRate = TEAM_FUND_EMISSION_RATE;
        for (uint256 i = 0; i < _years; i++) {
            _emissionRate =
                _emissionRate -
                ((_emissionRate * VESTING_DECREASING_RATIO) / RATIO_PRECISION);
        }

        uint256 _timeElapsed = _now - teamVesting.lastClaimed;
        uint256 _available = Math.min(
            _timeElapsed * _emissionRate,
            TEAM_FUND_ALLOCATION - teamVesting.vestedAmount
        );

        return _available;
    }

    function claimTeamFundRewards(address _to) external {
        require(msg.sender == team, "Cube: Team only");
        require(_to != address(0), "Cube: Address zero");
        require(treasury != address(0), "Cube: Treasury not set");

        uint256 _pending = unclaimedTeamFund();
        require(_pending > 0, "Cube: Nothing to claim");

        uint256 treasuryAmt = (_pending * 10) / 45; // 1/4.5 of team alloc
        uint256 teamAmt = _pending - treasuryAmt;

        _mint(_to, teamAmt);
        _mint(treasury, treasuryAmt);

        teamVesting.lastClaimed = block.timestamp;
        teamVesting.vestedAmount += _pending;
    }

    function setTreasury(address _treasury) public onlyOwner {
        require(_treasury != address(0), "Cube: Invalid treasury");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }
}
