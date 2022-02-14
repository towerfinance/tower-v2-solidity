// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../common/TowerProtocol.sol";

contract TowerV1Distributor is TowerProtocol {
    using SafeERC20 for IERC20;
    address public cube;

    struct Claim {
        uint256 claimable;
        uint256 lastClaimed;
        uint256 claimedAmount;
        uint256 emissionRate;
    }

    mapping(address => Claim) public claims;

    uint256 public vestingStartTime;

    uint256 public constant CLAIM_REWARD_ALLOCATION = 25_000_000 ether;
    uint256 public constant CLAIM_VESTING_DURATION = 1095 days;
    uint256 private constant ONE_YEAR = 365 days;
    uint256 public constant VESTING_DECREASING_RATIO = 290988; // 29.0988%

    event ClaimersSet();

    constructor(address _cube, uint256 _vestingStartTime) {
        cube = _cube;
        vestingStartTime = _vestingStartTime;
    }

    function pendingClaim(address _claimer) public view returns (uint256) {
        Claim memory claimer = claims[_claimer];
        uint256 _now = block.timestamp;
        if (_now <= claimer.lastClaimed) {
            return 0;
        }

        uint256 _fromEpoch = _now - vestingStartTime;
        uint256 _years = _fromEpoch / ONE_YEAR;

        uint256 _emissionRate = claimer.emissionRate;
        for (uint256 i = 0; i < _years; i++) {
            _emissionRate =
                _emissionRate -
                ((_emissionRate * VESTING_DECREASING_RATIO) / RATIO_PRECISION);
        }

        uint256 _timeElapsed = _now - claimer.lastClaimed;
        uint256 _available = Math.min(
            _timeElapsed * _emissionRate,
            claimer.claimable - claimer.claimedAmount
        );

        return _available;
    }

    function claim() external nonReentrant {
        require(claims[msg.sender].claimable > 0, "No claimable");
        uint256 _pending = pendingClaim(msg.sender);

        if (_pending > 0) {
            IERC20(cube).safeTransfer(msg.sender, _pending);
            claims[msg.sender].claimedAmount += _pending;
            claims[msg.sender].lastClaimed = block.timestamp;
        }
    }

    function setClaimers(address[] memory _claimers, uint256[] memory _amounts)
        external
        onlyOwner
    {
        require(_claimers.length == _amounts.length, "claimers != amounts");
        for (uint256 i = 0; i < _claimers.length; i++) {
            claims[_claimers[i]].claimable = _amounts[i];
            claims[_claimers[i]].lastClaimed = vestingStartTime;
            claims[_claimers[i]].claimedAmount = 0;
            claims[_claimers[i]].emissionRate =
                _amounts[i] /
                CLAIM_VESTING_DURATION;
        }

        emit ClaimersSet();
    }

    function transferTo(
        address _receiver,
        address _token,
        uint256 _amount
    ) public onlyOwner {
        IERC20 token = IERC20(_token);
        require(
            token.balanceOf(address(this)) >= _amount,
            "Not enough balance"
        );
        require(_amount > 0, "Zero amount");
        token.safeTransfer(_receiver, _amount);
    }
}
