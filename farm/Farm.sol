// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "../common/TowerProtocol.sol";
import "../common/EnableSwap.sol";
import "../interfaces/ITowerERC20.sol";
import "../interfaces/IFarm.sol";

contract Farm is IFarm, TowerProtocol, EnableSwap {
    using SafeERC20 for IERC20;
    using SafeERC20 for ITowerERC20;

    struct UserInfo {
        uint256 pid;
        uint256 amount;
        int256 rewardDebt;
        uint64 depositTime;
        VestingInfo[] vestings;
    }
    struct PoolInfo {
        uint64 allocPoint;
        uint64 lastRewardTime;
        uint256 accCubePerShare;
        uint64 lockDuration;
    }
    struct VestingInfo {
        uint64 startTime;
        uint256 amount;
    }

    uint64 private constant GENESIS_TIME = 345600;
    uint64 private constant VESTING_TERM = 604800;
    uint64 private constant ONE_DAY = 86400;
    uint64 private constant VESTING_COUNT = 4;
    ITowerERC20 public cube;
    IUniswapV2Pair public cubePair;

    /// @notice Info of each Farm pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each Farm pool.
    IERC20[] public lpToken;

    /// @notice Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    mapping(address => bool) public addedTokens;

    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 public cubePerSecond;

    uint256 public vestingPenalty;
    address public profitController;
    address public bankSafe;
    address public treasury;

    uint64 public startTime;

    event Deposit(
        address indexed user,
        address indexed to,
        uint256 indexed pid,
        uint256 amount
    );
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to
    );
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event Claim(
        address indexed user,
        uint256 indexed pid,
        uint256 vid,
        uint256 amount
    );
    event ClaimWithPenalty(
        address indexed user,
        uint256 indexed pid,
        uint256 vid,
        uint256 amount,
        uint256 penalty
    );
    event LogPoolAddition(
        uint256 indexed pid,
        uint256 allocPoint,
        IERC20 indexed lpToken,
        uint64 lockDuration
    );
    event LogSetPool(
        uint256 indexed pid,
        uint256 allocPoint,
        uint64 lockDuration
    );
    event LogUpdatePool(
        uint256 indexed pid,
        uint64 lastRewardTime,
        uint256 accAdded,
        uint256 accCubePerShare
    );
    event LogCubePerSecond(uint256 cubePerSecond);
    event LogVestingPenalty(uint256 penalty);
    event ProfitControllerUpdated(address profitController);
    event LogSetCube(address _cube, address cubePair);
    event DistributePenalty(uint256 bankSafeAmt, uint256 profitControllerAmt);
    event LogSetBankSafe(address bankSafe);
    event LogSetTreasury(address treasury);

    /// @param _cube The CUBE token contract address.
    constructor(
        address _cube,
        address _cubePair,
        address _swapController,
        address _profitController,
        address _bankSafe,
        address _treasury,
        uint64 _startTime
    ) {
        setCube(_cube, _cubePair);

        setSwapController(_swapController);
        setProfitController(_profitController);
        setBankSafe(_bankSafe);
        setTreasury(_treasury);

        setVestingPenalty(RATIO_PRECISION / 2); // 50%

        startTime = _startTime;
    }

    /// @notice Returns the number of Farm pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint64 _lockDuration
    ) public onlyOwner {
        require(addedTokens[address(_lpToken)] == false, "Token already added");
        massUpdatePools();

        totalAllocPoint += _allocPoint;
        lpToken.push(_lpToken);

        uint64 _startTime = _currentBlockTs() > startTime
            ? _currentBlockTs()
            : startTime;

        poolInfo.push(
            PoolInfo({
                allocPoint: SafeCast.toUint64(_allocPoint),
                lastRewardTime: _startTime,
                accCubePerShare: 0,
                lockDuration: _lockDuration
            })
        );
        addedTokens[address(_lpToken)] = true;
        emit LogPoolAddition(
            lpToken.length - 1,
            _allocPoint,
            _lpToken,
            _lockDuration
        );
    }

    /// @notice Update the given pool's CUBE allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint64 _lockDuration
    ) public onlyOwner {
        massUpdatePools();

        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        PoolInfo storage pool = poolInfo[_pid];
        pool.allocPoint = SafeCast.toUint64(_allocPoint);
        pool.lockDuration = SafeCast.toUint64(_lockDuration);
        emit LogSetPool(_pid, _allocPoint, _lockDuration);
    }

    /// @notice Sets the CUBE per second to be distributed. Can only be called by the owner.
    function setCubePerSecond(uint256 _cubePerSecond) public onlyOwner {
        massUpdatePools();

        cubePerSecond = _cubePerSecond;
        emit LogCubePerSecond(cubePerSecond);
    }

    function setVestingPenalty(uint256 _penalty) public onlyOwner {
        vestingPenalty = _penalty;
        emit LogVestingPenalty(vestingPenalty);
    }

    /// @dev Calculated amount of accCubePerShare to add to the pool.
    function _calcAccCubeToAdd(uint256 _pid) internal view returns (uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        uint256 _lpSupply = lpToken[_pid].balanceOf(address(this));
        uint256 _lpDecimals = ERC20(address(lpToken[_pid])).decimals();
        uint64 _currentTs = _currentBlockTs();
        if (_currentTs <= pool.lastRewardTime || _lpSupply <= 0) {
            return 0;
        }
        uint256 _time = _currentTs - pool.lastRewardTime;
        uint256 _cubeReward = (_time * cubePerSecond * pool.allocPoint) /
            totalAllocPoint;
        return (_cubeReward * (10**_lpDecimals)) / _lpSupply;
    }

    /// @notice View function to see pending CUBE on frontend.
    function pendingCube(uint256 _pid, address _user)
        external
        view
        returns (uint256 pending)
    {
        PoolInfo memory _pool = poolInfo[_pid];
        UserInfo memory _userInfo = userInfo[_pid][_user];

        uint256 _accCubePerShare = _pool.accCubePerShare +
            _calcAccCubeToAdd(_pid);
        pending = SafeCast.toUint256(
            int256((_userInfo.amount * _accCubePerShare) / CUBE_PRECISION) -
                _userInfo.rewardDebt
        );
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 _pid)
            public
            nonReentrant
            returns (PoolInfo memory pool)
        {
        pool = poolInfo[_pid];
        uint256 _accToAdd = _calcAccCubeToAdd(_pid);
        if (_accToAdd > 0) {
            pool.accCubePerShare += _accToAdd;
        }
        uint64 _currentTs = _currentBlockTs();
        if (_currentTs > pool.lastRewardTime) {
            pool.lastRewardTime = _currentTs;
            poolInfo[_pid] = pool;
            emit LogUpdatePool(
                _pid,
                pool.lastRewardTime,
                _accToAdd,
                pool.accCubePerShare
            );
        }
    }

    /// @notice Deposit LP tokens to Farm for CUBE allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _to
    ) public override {
        PoolInfo memory _pool = updatePool(_pid);
        UserInfo storage _user = userInfo[_pid][_to];

        lpToken[_pid].safeTransferFrom(msg.sender, address(this), _amount);

        // Effects
        _user.pid = _pid;
        _user.amount += _amount;
        _user.rewardDebt += int256(
            (_amount * _pool.accCubePerShare) / CUBE_PRECISION
        );
        _user.depositTime = _currentBlockTs();

        for (uint256 i = _user.vestings.length; i < VESTING_COUNT; i++) {
            _user.vestings.push(VestingInfo({startTime: 0, amount: 0}));
        }

        emit Deposit(msg.sender, _to, _pid, _amount);
    }

    /// @notice Withdraw LP tokens from Farm.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo memory _pool = updatePool(_pid);
        UserInfo storage _user = userInfo[_pid][msg.sender];

        require(
            _user.depositTime + _pool.lockDuration <= _currentBlockTs(),
            "Farm: Withdraw lock"
        );

        // Effects
        _user.rewardDebt -= int256(
            (_amount * _pool.accCubePerShare) / CUBE_PRECISION
        );
        _user.amount -= _amount;

        lpToken[_pid].safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    /// @notice Harvest proceeds for transaction sender.
    function harvest(uint256 _pid) public override {
        PoolInfo memory _pool = updatePool(_pid);
        UserInfo storage _user = userInfo[_pid][msg.sender];
        int256 _accumulatedCube = int256(
            (_user.amount * _pool.accCubePerShare) / CUBE_PRECISION
        );
        uint256 _pendingCube = SafeCast.toUint256(
            _accumulatedCube - _user.rewardDebt
        );

        // Effects
        _user.rewardDebt = _accumulatedCube;

        // Interactions
        if (_pendingCube > 0) {
            _addToVesting(_user, _pendingCube);
        }

        emit Harvest(msg.sender, _pid, _pendingCube);
    }

    function claim(uint256 _pid, uint256 _vid) public override nonReentrant {
        UserInfo storage _user = userInfo[_pid][msg.sender];
        VestingInfo storage _vesting = _user.vestings[_vid];

        require(_vesting.amount > 0, "Farm: Nothing to claim");
        require(canClaimVesting(_vesting.startTime), "Farm: Not yet to claim");

        uint256 _amount = _vesting.amount;
        _vesting.amount = 0;

        cube.mintByFarm(msg.sender, _amount);

        emit Claim(msg.sender, _pid, _vid, _amount);
    }

    function claimWithPenalty(uint256 _pid, uint256 _vid)
        public
        override
        nonReentrant
    {
        UserInfo storage _user = userInfo[_pid][msg.sender];
        VestingInfo storage _vesting = _user.vestings[_vid];

        require(_vesting.amount > 0, "Farm: Nothing to claim");
        require(
            !canClaimVesting(_vesting.startTime),
            "Farm: Can normally claim"
        );

        uint256 _penalty = (_vesting.amount * vestingPenalty) / RATIO_PRECISION;
        uint256 _amount = _vesting.amount - _penalty;
        _vesting.amount = 0;

        cube.mintByFarm(msg.sender, _amount);

        _distributePenalty(_penalty);

        emit ClaimWithPenalty(msg.sender, _pid, _vid, _amount, _penalty);
    }

    /// @dev Distribute penalty (CUBE) to BankSafe (2/3 -> CUBE-USDC LP) and ProfitController (1/3 -> CUBE).
    function _distributePenalty(uint256 _amount) internal {
        require(_amount > 0, "Farm: Aero amount");
        require(treasury != address(0), "Farm: Treasury not set");
        require(
            profitController != address(0),
            "Farm: ProfitController not set"
        );

        uint256 _treasuryAmt = (_amount * 2) / 3;

        cube.mintByFarm(address(this), _amount);
        cube.safeApprove(address(swapController), 0);
        cube.safeApprove(address(swapController), _treasuryAmt);
        uint256 lpAmt = swapController.zapInCube(_treasuryAmt, 0, 0);

        require(cubePair.transfer(treasury, lpAmt), "Farm: Failed to transfer");

        uint256 _profitControllerAmt = _amount - _treasuryAmt;
        if (_profitControllerAmt > 0) {
            cube.safeTransfer(profitController, _profitControllerAmt);
        }

        emit DistributePenalty(_treasuryAmt, _profitControllerAmt);
    }

    /// @notice Withdraw LP tokens from Farm and harvest proceeds for transaction sender.
    function withdrawAndHarvest(uint256 _pid, uint256 _amount) public override {
        PoolInfo memory _pool = updatePool(_pid);
        UserInfo storage _user = userInfo[_pid][msg.sender];

        require(
            _user.depositTime + _pool.lockDuration <= _currentBlockTs(),
            "Farm: Withdraw lock"
        );

        int256 _accumulatedCube = int256(
            (_user.amount * _pool.accCubePerShare) / CUBE_PRECISION
        );
        uint256 _pendingCube = SafeCast.toUint256(
            _accumulatedCube - _user.rewardDebt
        );

        // Effects
        _user.rewardDebt =
            _accumulatedCube -
            int256((_amount * _pool.accCubePerShare) / CUBE_PRECISION);
        _user.amount -= _amount;

        // Interactions
        if (_pendingCube > 0) {
            _addToVesting(_user, _pendingCube);
        }

        lpToken[_pid].safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _pid, _amount);
        emit Harvest(msg.sender, _pid, _pendingCube);
    }

    function _addToVesting(UserInfo storage _user, uint256 _amount) private {
        require(_amount > 0, "Farm: Nothing to add vesting");
        uint8 _slot = vestingSlot();
        VestingInfo storage _vesting = _user.vestings[_slot];

        if (_vesting.amount > 0 && canClaimVesting(_vesting.startTime)) {
            // Claim amount in vesting slot
            uint256 _amountToTransfer = _vesting.amount;
            _vesting.amount = 0;

            cube.mintByFarm(msg.sender, _amountToTransfer);
        }

        if (_vesting.amount == 0) {
            _vesting.startTime = _calcNextVestingStart();
        }

        _vesting.amount += _amount;
    }

    function _calcNextVestingStart() private view returns (uint64) {
        uint64 _currentTs = _currentBlockTs();
        uint64 _startTime = (_currentTs) -
            (_currentTs % VESTING_TERM) +
            GENESIS_TIME;
        if (_startTime <= _currentTs) {
            _startTime += VESTING_TERM;
        }
        return _startTime;
    }

    function canClaimVesting(uint64 _startTime) public view returns (bool) {
        return
            _currentBlockTs() >=
            (_startTime + (VESTING_TERM * (VESTING_COUNT - 1)));
    }

    function vestingSlot() public view returns (uint8) {
        uint64 _vestringStart = _calcNextVestingStart();
        return uint8((_vestringStart / VESTING_TERM) % VESTING_COUNT);
    }

    function getUserInfo(address _user)
        external
        view
        returns (UserInfo[] memory)
    {
        UserInfo[] memory _returnInfos = new UserInfo[](poolInfo.length);

        for (uint256 i = 0; i < poolInfo.length; i++) {
            UserInfo memory _userInfo = userInfo[i][_user];
            _returnInfos[i] = _userInfo;
        }

        return _returnInfos;
    }

    function getLpToken(uint256 _pid) external view override returns (address) {
        return address(lpToken[_pid]);
    }

    function setProfitController(address _profitController) public onlyOwner {
        require(_profitController != address(0), "Farm: Address zero");
        profitController = _profitController;
        emit ProfitControllerUpdated(_profitController);
    }

    function setCube(address _cube, address _cubePair) public onlyOwner {
        require(_cube != address(0), "Farm: Address zero");
        require(_cubePair != address(0), "Farm: Address zero");
        cube = ITowerERC20(_cube);
        cubePair = IUniswapV2Pair(_cubePair);
        emit LogSetCube(_cube, _cubePair);
    }

    function setBankSafe(address _bankSafe) public onlyOwner {
        require(_bankSafe != address(0), "Farm: Address zero");
        bankSafe = _bankSafe;
        emit LogSetBankSafe(bankSafe);
    }

    function setTreasury(address _treasury) public onlyOwner {
        require(_treasury != address(0), "Farm: Address zero");
        treasury = _treasury;
        emit LogSetTreasury(treasury);
    }
}
