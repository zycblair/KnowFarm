// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// import "./helpers/ERC20.sol";
// import "./libraries/Address.sol";
// import "./libraries/SafeERC20.sol";
// import "./libraries/EnumerableSet.sol";
// import "./helpers/Ownable.sol";
// import "./helpers/ReentrancyGuard.sol";
// import "./interfaces/IWBNB.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

abstract contract RewardToken is ERC20 {
    function mint(address _to, uint256 _amount) public virtual;
}

contract KnowFarm is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 shares; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    struct PoolInfo {
        IERC20 want; // Address of the want token.
        uint256 allocPoint; // How many allocation points assigned to this pool. token to distribute per block.
        uint256 lastRewardBlock; // Last block number that token distribution occurs.
        uint256 accPerShare; // Accumulated token per share, times 1e12. See below.
        uint256 sharesTotal;
    }

    // token contract
    address public rewardTokenAddress; 
    uint256 public RewardMaxSupply = 10000000e18;
    uint256 public rewardPerBlock = 5787e14; // reward tokens created per block
    uint256 public startBlock = 0; // https://bscscan.com/block/countdown/10150000
    // https://testnet.bscscan.com/block/countdown/11890000

    PoolInfo public poolInfo; // Info of each pool.
    mapping(address => UserInfo) public userInfo; // Info of each user that stakes LP tokens.
    uint256 public totalAllocPoint = 100; // Total allocation points. Must be the sum of all allocation points in all pools.

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
        
    constructor(address want, uint256 allocPoint) public {
        poolInfo.want = IERC20(want);
        poolInfo.allocPoint = allocPoint;  
        poolInfo.lastRewardBlock = 0;      
        poolInfo.accPerShare = 0;
    }

    function setStartBlock(uint256 _startBlock) public onlyOwner {
        startBlock = _startBlock;
        poolInfo.lastRewardBlock = block.number > startBlock ? block.number : startBlock;      
    }

    function setRewardPerBlock(uint256 _rewardPerBlock) public onlyOwner {
        rewardPerBlock = _rewardPerBlock;
    }

    function setRewardTokenAddress(address _rewardTokenAddress) public onlyOwner {
        rewardTokenAddress = _rewardTokenAddress;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (IERC20(rewardTokenAddress).totalSupply() >= RewardMaxSupply) {
            return 0;
        }
        return _to.sub(_from);
    }

    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 accPerShare = poolInfo.accPerShare;
        if (block.number > poolInfo.lastRewardBlock && poolInfo.sharesTotal > 0) {
            uint256 multiplier = getMultiplier(poolInfo.lastRewardBlock, block.number);
            uint256 reward = multiplier.mul(rewardPerBlock).mul(poolInfo.allocPoint).div(totalAllocPoint);
            accPerShare = poolInfo.accPerShare.add(
                reward.mul(1e12).div(poolInfo.sharesTotal)
            );
        }
        return user.shares.mul(accPerShare).div(1e12).sub(user.rewardDebt);
    }

    // View function to see staked Want tokens on frontend.
    function stakedTokens(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        return user.shares;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        updatePool();
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool() public {
        if (block.number <= poolInfo.lastRewardBlock) {
            return;
        }
        uint256 sharesTotal = poolInfo.sharesTotal;
        if (sharesTotal == 0) {
            poolInfo.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(poolInfo.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            return;
        }
        uint256 reward =
            multiplier.mul(rewardPerBlock).mul(poolInfo.allocPoint).div(
                totalAllocPoint
            );

        RewardToken(rewardTokenAddress).mint(address(this), reward);
        poolInfo.accPerShare = poolInfo.accPerShare.add(
            reward.mul(1e12).div(sharesTotal)
        );
        
        poolInfo.lastRewardBlock = block.number;
    }

    function deposit(uint256 _wantAmt) public payable nonReentrant {
        if(poolInfo.lastRewardBlock == 0) {
            poolInfo.lastRewardBlock = block.number;    
        }

        updatePool();
        UserInfo storage user = userInfo[msg.sender];
        if (user.shares > 0) {
            uint256 pending = user.shares.mul(poolInfo.accPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeRewardTransfer(msg.sender, pending);
            }
        }

        if(_wantAmt > 0) {
            poolInfo.want.safeTransferFrom(address(msg.sender), address(this), _wantAmt);
            user.shares = user.shares.add(_wantAmt);
        }

        user.rewardDebt = user.shares.mul(poolInfo.accPerShare).div(1e12);
        
        emit Deposit(msg.sender, _wantAmt);
    }

    // Withdraw LP tokens from boxfarm.
    function withdraw(uint256 _wantAmt) public nonReentrant {
        updatePool();

        UserInfo storage user = userInfo[msg.sender];
        require(user.shares > 0, "user.shares is 0");
        require(poolInfo.sharesTotal > 0, "sharesTotal is 0");
        
        uint256 pending = user.shares.mul(poolInfo.accPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeRewardTransfer(msg.sender, pending);
        }
        
        // Withdraw want tokens
        uint256 amount = user.shares;
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 sharesRemoved = _wantAmt;
            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }

            uint256 wantBal = IERC20(poolInfo.want).balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }

            poolInfo.want.safeTransfer(address(msg.sender), _wantAmt);
        }

        user.rewardDebt = user.shares.mul(poolInfo.accPerShare).div(1e12);

        emit Withdraw(msg.sender, _wantAmt);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.shares;
        poolInfo.want.safeTransfer(address(msg.sender), amount);
        
        user.shares = 0;
        user.rewardDebt = 0;
        poolInfo.sharesTotal = poolInfo.sharesTotal.sub(amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    function safeRewardTransfer(address _to, uint256 _rewardAmt) internal {
        uint256 rewardBal = IERC20(rewardTokenAddress).balanceOf(address(this));
        if (_rewardAmt > rewardBal) {
            IERC20(rewardTokenAddress).transfer(_to, rewardBal);
        } else {
            IERC20(rewardTokenAddress).transfer(_to, _rewardAmt);
        }
    }
}
