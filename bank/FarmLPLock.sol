// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../common/TowerProtocol.sol";
import "../interfaces/IFarm.sol";

contract FarmLPLock is TowerProtocol {
    using SafeERC20 for IERC20;
    IFarm public farm;

    struct Lock {
        uint256 amount;
        uint256 startTime;
    }

    mapping(address => Lock) public lpLocks;
    uint256 public constant LOCK_DURATION = 30 days;

    event FarmUpdated(address farm);
    event FarmDeposited(
        uint256 pid,
        uint256 amount,
        address to,
        uint256 lockStart
    );
    event FarmHarvested(uint256 pid);
    event FarmClaimed(uint256 pid, uint256 vid);
    event FarmWithdrawnAndHarvested(uint256 pid, uint256 amount);
    event FarmHarvestedAndClaimedWithPenalty(uint256 pid, uint256 vid);

    constructor(address _farm) {
        setFarm(_farm);
    }

    function depositFarmAndLockLP(
        uint256 pid,
        uint256 amount,
        address to,
        uint256 lockStart
    ) public onlyOwner {
        require(amount > 0, "zero amount");
        IERC20 token = IERC20(farm.getLpToken(pid));

        require(token.balanceOf(address(this)) >= amount, "Not enough balance");

        require(lockStart >= block.timestamp, "Lock must be in the future");
        lpLocks[address(token)] = Lock({amount: amount, startTime: lockStart});

        token.safeApprove(address(farm), 0);
        token.safeApprove(address(farm), amount);
        farm.deposit(pid, amount, to);
        emit FarmDeposited(pid, amount, to, lockStart);
    }

    function harvestFarm(uint256 pid) public onlyOwnerOrOperator {
        farm.harvest(pid);
        emit FarmHarvested(pid);
    }

    function claimFarm(uint256 pid, uint256 vid) public onlyOwnerOrOperator {
        farm.claim(pid, vid);
        emit FarmClaimed(pid, vid);
    }

    function harvestAndClaimWithPenalty(uint256 pid, uint256 vid)
        public
        onlyOwnerOrOperator
    {
        harvestFarm(pid);
        claimWithPenaltyFarm(pid, vid);
        emit FarmHarvestedAndClaimedWithPenalty(pid, vid);
    }

    function claimWithPenaltyFarm(uint256 pid, uint256 vid)
        public
        onlyOwnerOrOperator
    {
        farm.claimWithPenalty(pid, vid);
        emit FarmClaimed(pid, vid);
    }

    function withdrawAndHarvestFarm(uint256 pid, uint256 amount)
        public
        onlyOwner
    {
        require(amount > 0, "FarmLPLock: Zero amount");

        IERC20 token = IERC20(farm.getLpToken(pid));
        require(
            lpLocks[address(token)].startTime + LOCK_DURATION <=
                block.timestamp,
            "FarmLPLock: withdraw lock"
        );

        farm.withdrawAndHarvest(pid, amount);
        emit FarmWithdrawnAndHarvested(pid, amount);
    }

    function setFarm(address _farm) public onlyOwner {
        require(_farm != address(0), "Framable: Zero address");
        farm = IFarm(_farm);
        emit FarmUpdated(_farm);
    }

    function transferTo(
        address _receiver,
        address _token,
        uint256 _amount
    ) public onlyOwner {
        IERC20 token = IERC20(_token);
        require(
            token.balanceOf(address(this)) >= _amount,
            "FarmLPLock: Not enough balance"
        );
        require(_amount > 0, "Zero amount");
        token.safeTransfer(_receiver, _amount);
    }
}
