// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/IProfitController.sol";
import "../interfaces/ICubeStake.sol";
import "../common/TowerProtocol.sol";

contract CubeStake is
    ERC20("CubeStake", "xCUBE"),
    ICubeStake,
    Initializable,
    TowerProtocol
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public cube;
    bool public stakePaused = false;

    uint256 public constant LOCK_DURATION = 86400 * 7; // 7 days
    uint256 public constant EPOCH_PERIOD = 1 days;

    struct EpochDistribution {
        uint256 lastRewardTime;
        uint256 lockAmount;
        uint256 stepAmount;
    }

    struct UserInfo {
        uint256 unlockTime;
        uint256 xCubeAmount;
    }

    EpochDistribution public epoch;

    address public profitController;

    mapping(address => UserInfo) public userLocks;

    modifier onlyProfitController() {
        require(
            msg.sender == owner() || msg.sender == profitController,
            "Only profit controller"
        );
        _;
    }

    event ProfitDistributed(uint256 amount);
    event ProfitControllerUpdated(address profitController);
    event StakePaused();

    constructor(IERC20 _cube) {
        cube = _cube;
    }

    function init(address _profitController) external initializer onlyOwner {
        setProfitController(_profitController);
    }

    function calcAccAmt() public view returns (uint256) {
        if (block.timestamp < epoch.lastRewardTime) {
            return 0;
        }
        uint256 _now = block.timestamp;
        uint256 epochElapsed = _now - epoch.lastRewardTime;
        uint256 accAmt = epoch.stepAmount * epochElapsed;
        return accAmt;
    }

    function updateStakeLock() public {
        uint256 accAmt = calcAccAmt();
        if (epoch.lockAmount > accAmt) {
            epoch.lockAmount -= accAmt;
        } else {
            epoch.lockAmount = 0;
        }
        epoch.lastRewardTime = block.timestamp;
    }

    function pendingxCube(address _user) public view returns (uint256) {
        uint256 totalShares = totalSupply();

        uint256 lockAcc = epoch.lockAmount - calcAccAmt();
        uint256 adjustedTotalCube = cube.balanceOf(address(this)).sub(lockAcc);
        uint256 xCubeAmt = balanceOf(_user).mul(adjustedTotalCube).div(
            totalShares
        );
        return xCubeAmt;
    }

    function stake(uint256 _amount) public nonReentrant {
        require(!stakePaused, "Stake is paused");
        updateStakeLock();

        uint256 _unlockTime = block.timestamp.add(LOCK_DURATION);
        uint256 _totalCube = cube.balanceOf(address(this));
        uint256 _totalShares = totalSupply();

        uint256 _xCubeOut = 0;
        if (_totalShares == 0 || _totalCube == 0) {
            _xCubeOut = _amount;
        } else {
            uint256 _adjustedTotalCube = _totalCube.sub(epoch.lockAmount);
            _xCubeOut = _amount.mul(_totalShares).div(_adjustedTotalCube);
        }

        require(_xCubeOut > 0, "Stake: Out is 0");

        UserInfo storage userInfo = userLocks[msg.sender];
        userInfo.unlockTime = _unlockTime;
        userInfo.xCubeAmount += _xCubeOut;

        _mint(msg.sender, _xCubeOut);
        cube.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function unstake(uint256 _share) public nonReentrant {
        require(!stakePaused, "Stake: Paused");
        require(_share <= balanceOf(msg.sender), "Stake: >balance");

        UserInfo storage userInfo = userLocks[msg.sender];
        require(userInfo.unlockTime <= block.timestamp, "Stake: Not expired");
        require(userInfo.xCubeAmount >= _share, "Stake: Not Staked");

        updateStakeLock();

        uint256 totalShares = totalSupply();
        uint256 totalCube = cube.balanceOf(address(this));

        uint256 adjustedTotalCube = totalCube.sub(epoch.lockAmount);
        uint256 cubeAmount = _share.mul(adjustedTotalCube).div(totalShares);

        userInfo.xCubeAmount -= _share;
        _burn(msg.sender, _share);
        cube.safeTransfer(msg.sender, cubeAmount);
    }

    function cubePerShare() external view returns (uint256) {
        uint256 totalShares = totalSupply();
        uint256 totalCube = cube.balanceOf(address(this));

        if (totalShares == 0 || totalCube == 0) {
            return 1e18;
        }

        uint256 adjustedTotalCube = totalCube.sub(epoch.lockAmount).add(
            calcAccAmt()
        );

        uint256 cubeAmt = (adjustedTotalCube).mul(1e18).div(totalShares);
        return cubeAmt;
    }

    function userLockInfo(address _user)
        external
        view
        returns (uint256, uint256)
    {
        UserInfo memory _userInfo = userLocks[_user];
        uint256 unlockTime = _userInfo.unlockTime;
        if (unlockTime == 0) {
            return (0, 0);
        }
        uint256 lockRemaining = unlockTime.sub(block.timestamp);
        return (unlockTime, lockRemaining);
    }

    function distribute(uint256 _amount)
        external
        override
        onlyProfitController
    {
        require(_amount != 0, "Amount must be greater than 0");
        updateStakeLock();

        uint256 _newLockAmount = epoch.lockAmount.add(_amount);
        uint256 _stepAmount = _newLockAmount.div(EPOCH_PERIOD);
        epoch = EpochDistribution({
            lastRewardTime: block.timestamp,
            lockAmount: _newLockAmount,
            stepAmount: _stepAmount
        });
        emit ProfitDistributed(_amount);
        cube.safeTransferFrom(profitController, address(this), _amount);
    }

    function setStakePaused() public onlyOwnerOrOperator {
        stakePaused = !stakePaused;
        emit StakePaused();
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

    function setProfitController(address _profitController) public onlyOwner {
        require(_profitController != address(0), "Invalid address");
        profitController = _profitController;
        emit ProfitControllerUpdated(_profitController);
    }
}
