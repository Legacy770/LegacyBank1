// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";

/// @title LegacyBank
/// @notice Time-locked stablecoin savings. Funds are locked (not staked) until a chosen
///         unlock time. Early exit costs a 10% penalty. Operators may supply part of the
///         pooled funds to Aave; withdrawals auto-pull from Aave if idle liquidity is short.
contract LegacyBank is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BPS = 10_000;
    uint256 public constant DEPOSIT_FEE_BPS = 50; // 0.5%
    uint256 public constant EARLY_PENALTY_BPS = 1_000; // 10%
    uint256 public constant MIN_LOCK = 120 days; // ~4 months
    uint256 public constant MAX_LOCK = 1095 days; // 3 years

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    struct Position {
        address owner;
        uint64 unlockTime;
        bool closed;
        address token;
        uint128 amount; // net amount locked (after fee)
    }

    IAavePool public immutable aavePool;
    address public treasury;
    uint256 public maxAllocationBps; // max share of totalLocked that may sit in Aave

    uint256 public nextPositionId;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) private _userPositionIds;

    mapping(address => bool) public supportedToken;
    mapping(address => address) public aTokenOf;
    mapping(address => bool) public operators;

    mapping(address => uint256) public totalLocked; // user liabilities per token
    mapping(address => uint256) public allocated; // principal currently supplied to Aave

    /*//////////////////////////////////////////////////////////////
                              EVENTS / ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Backend indexer: award points from this event. `lockedAmount` is net of fee.
    event Deposited(
        uint256 indexed id,
        address indexed user,
        address indexed token,
        uint256 grossAmount,
        uint256 fee,
        uint256 lockedAmount,
        uint256 lockDuration,
        uint256 unlockTime
    );
    event Withdrawn(uint256 indexed id, address indexed user, address indexed token, uint256 amount);
    event EmergencyWithdrawn(
        uint256 indexed id, address indexed user, address indexed token, uint256 returned, uint256 penalty
    );
    event Allocated(address indexed token, uint256 amount);
    event Deallocated(address indexed token, uint256 amount);
    event YieldHarvested(address indexed token, uint256 amount);
    event TokenConfigured(address indexed token, bool supported, address aToken);
    event TreasuryUpdated(address treasury);
    event OperatorUpdated(address operator, bool enabled);
    event MaxAllocationUpdated(uint256 bps);

    error UnsupportedToken();
    error InvalidDuration();
    error ZeroAmount();
    error NotPositionOwner();
    error PositionClosed();
    error StillLocked();
    error AlreadyUnlocked();
    error NotOperator();
    error NoAToken();
    error ExceedsAllocationCap();
    error InsufficientAllocated();
    error AaveWithdrawShortfall();
    error InvalidAddress();
    error InvalidBps();

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner()) revert NotOperator();
        _;
    }

    constructor(address initialOwner, address treasury_, address aavePool_, uint256 maxAllocationBps_)
        Ownable(initialOwner)
    {
        if (treasury_ == address(0) || aavePool_ == address(0)) revert InvalidAddress();
        if (maxAllocationBps_ > BPS) revert InvalidBps();
        treasury = treasury_;
        aavePool = IAavePool(aavePool_);
        maxAllocationBps = maxAllocationBps_;
    }

    /*//////////////////////////////////////////////////////////////
                               USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock `amount` of `token` for `duration` seconds. 0.5% fee is taken upfront.
    function deposit(address token, uint256 amount, uint256 duration)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        if (!supportedToken[token]) revert UnsupportedToken();
        if (duration < MIN_LOCK || duration > MAX_LOCK) revert InvalidDuration();
        if (amount == 0) revert ZeroAmount();

        // Measure actual received amount (safe for fee-on-transfer tokens)
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;

        uint256 fee = (received * DEPOSIT_FEE_BPS) / BPS;
        uint256 net = received - fee;
        if (net == 0) revert ZeroAmount();

        if (fee > 0) IERC20(token).safeTransfer(treasury, fee);

        uint64 unlockTime = uint64(block.timestamp + duration);
        id = nextPositionId++;
        positions[id] = Position({
            owner: msg.sender,
            unlockTime: unlockTime,
            closed: false,
            token: token,
            amount: uint128(net)
        });
        _userPositionIds[msg.sender].push(id);
        totalLocked[token] += net;

        emit Deposited(id, msg.sender, token, received, fee, net, duration, unlockTime);
    }

    /// @notice Withdraw full principal after the lock has expired.
    function withdraw(uint256 id) external nonReentrant {
        Position storage p = positions[id];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (p.closed) revert PositionClosed();
        if (block.timestamp < p.unlockTime) revert StillLocked();

        p.closed = true;
        uint256 amount = p.amount;
        address token = p.token;
        totalLocked[token] -= amount;

        _ensureLiquidity(token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawn(id, msg.sender, token, amount);
    }

    /// @notice Exit before unlock. 10% penalty goes to the treasury.
    function emergencyWithdraw(uint256 id) external nonReentrant {
        Position storage p = positions[id];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (p.closed) revert PositionClosed();
        if (block.timestamp >= p.unlockTime) revert AlreadyUnlocked();

        p.closed = true;
        uint256 amount = p.amount;
        address token = p.token;
        totalLocked[token] -= amount;

        uint256 penalty = (amount * EARLY_PENALTY_BPS) / BPS;
        uint256 returned = amount - penalty;

        _ensureLiquidity(token, amount);
        IERC20(token).safeTransfer(msg.sender, returned);
        if (penalty > 0) IERC20(token).safeTransfer(treasury, penalty);

        emit EmergencyWithdrawn(id, msg.sender, token, returned, penalty);
    }

    /*//////////////////////////////////////////////////////////////
                              AAVE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Supply idle funds to Aave, capped at maxAllocationBps of user liabilities.
    function allocateToAave(address token, uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (aTokenOf[token] == address(0)) revert NoAToken();
        if (allocated[token] + amount > (totalLocked[token] * maxAllocationBps) / BPS) {
            revert ExceedsAllocationCap();
        }

        allocated[token] += amount;
        IERC20(token).forceApprove(address(aavePool), amount);
        aavePool.supply(token, amount, address(this), 0);

        emit Allocated(token, amount);
    }

    /// @notice Pull principal back from Aave into this contract.
    function deallocateFromAave(address token, uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > allocated[token]) revert InsufficientAllocated();

        allocated[token] -= amount;
        uint256 got = aavePool.withdraw(token, amount, address(this));
        if (got < amount) revert AaveWithdrawShortfall();

        emit Deallocated(token, amount);
    }

    /// @notice Send accrued Aave yield (aToken balance above tracked principal) to the treasury.
    function harvestYield(address token) external onlyOperator nonReentrant {
        address aToken = aTokenOf[token];
        if (aToken == address(0)) revert NoAToken();

        uint256 bal = IERC20(aToken).balanceOf(address(this));
        uint256 principal = allocated[token];
        if (bal <= principal) return;

        uint256 yield_ = bal - principal;
        uint256 got = aavePool.withdraw(token, yield_, treasury);
        emit YieldHarvested(token, got);
    }

    /// @dev If idle balance can't cover `amount`, pull the shortfall from Aave.
    function _ensureLiquidity(address token, uint256 amount) internal {
        uint256 idle = IERC20(token).balanceOf(address(this));
        if (idle >= amount) return;

        uint256 need = amount - idle;
        if (need > allocated[token]) revert InsufficientAllocated();
        allocated[token] -= need;

        uint256 got = aavePool.withdraw(token, need, address(this));
        if (got < need) revert AaveWithdrawShortfall();
        emit Deallocated(token, need);
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Whitelist/disable a stablecoin. Disabling only blocks new deposits.
    function configureToken(address token, bool supported, address aToken) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        supportedToken[token] = supported;
        aTokenOf[token] = aToken;
        emit TokenConfigured(token, supported, aToken);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setOperator(address operator, bool enabled) external onlyOwner {
        operators[operator] = enabled;
        emit OperatorUpdated(operator, enabled);
    }

    function setMaxAllocationBps(uint256 bps) external onlyOwner {
        if (bps > BPS) revert InvalidBps();
        maxAllocationBps = bps;
        emit MaxAllocationUpdated(bps);
    }

    /// @dev Pausing blocks deposits only. Withdrawals always remain open.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                   VIEWS
    //////////////////////////////////////////////////////////////*/

    function getUserPositionIds(address user) external view returns (uint256[] memory) {
        return _userPositionIds[user];
    }

    function getUserPositions(address user) external view returns (uint256[] memory ids, Position[] memory out) {
        ids = _userPositionIds[user];
        out = new Position[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            out[i] = positions[ids[i]];
        }
    }
}