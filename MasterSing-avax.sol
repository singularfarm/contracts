//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/Ichef.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./SingToken.sol";

contract MasterSing is Ownable, ReentrancyGuard{
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;
    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 earnedDebt;
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. SINGs to distribute per block.
        uint256 lastRewardTime;  // Last block number that SINGs distribution occurs.
        uint256 accSingPerShare;   // Accumulated SINGs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
        uint256 totalcap;
        bool isStrat;
        uint stratId;
        uint earned;
        uint earnfee;
        uint accEarnPerShare;
    }
    
    // The SING TOKEN!
    SingToken public sing;
    // Dev address.
    address public devaddr;
    address feeAddress;
    uint256 public singPerSec;
    //Strat target is fixed and cannot change.
    IChef public WL_master=IChef(0xd6a4F121CA35509aF06A0Be99093d08462f53052);//MasterJoe
    IBEP20 public WL_earn=IBEP20(0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd);//JOE
    IUniswapV2Router02 public JoeRouter = IUniswapV2Router02(0xcF0feBd3f17CEf5b47b0cD257aCf6025c5BFf3b7);
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint = 0;
    uint256 public startTime;
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor() public { 
    }
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }
    function initiate(SingToken _sing,address _devaddr,address _feeAddress,uint256 _singPerSec,uint256 _startTime) public onlyOwner{
        require(_startTime>block.timestamp || poolInfo.length==0,"start block passed");
        startTime=_startTime; 
        sing = _sing;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        singPerSec = _singPerSec;
        for(uint i=0;i<poolInfo.length;i++){
            poolInfo[i].lastRewardTime=startTime;
        }
    }
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _isStrat,uint _stratId,uint _earnfee,bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 400, "max 4%");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accSingPerShare: 0,
            depositFeeBP: _depositFeeBP,
            totalcap:0,
            isStrat:_isStrat,
            stratId : _stratId,
            earned:0,
            earnfee:_earnfee,
            accEarnPerShare:0
        }));
    }

    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP,bool _isStrat,uint _stratId,uint _earnfee, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 400, "max 4%");
        if (_withUpdate) {
            massUpdatePools();
        }
        PoolInfo storage pool = poolInfo[_pid];
        totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        pool.allocPoint = _allocPoint;
        pool.depositFeeBP = _depositFeeBP;
        pool.isStrat=_isStrat;
        pool.stratId=_stratId;
        pool.earnfee=_earnfee;
    }
    function pendingSing(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSingPerShare = pool.accSingPerShare;
        if (block.timestamp > pool.lastRewardTime && pool.totalcap != 0) {
            uint256 multiplier = block.timestamp.sub(pool.lastRewardTime);
            uint256 singReward = multiplier.mul(singPerSec).mul(pool.allocPoint).div(totalAllocPoint);
            accSingPerShare = accSingPerShare.add(singReward.mul(1e12).div(pool.totalcap));
        }
        return user.amount.mul(accSingPerShare).div(1e12).sub(user.rewardDebt);
    }
    function pendingEarned(uint _pid,address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        if(pool.isStrat==false){
            return 0;
        }
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accEarnPerShare=pool.accEarnPerShare;
        if(pool.totalcap!=0){
            (uint256 pending,,,)=WL_master.pendingTokens(pool.stratId, address(this));
            uint256 earn=pending.mul(100-pool.earnfee).div(100);
            accEarnPerShare=accEarnPerShare.add(earn.mul(1e12).div(pool.totalcap));
        }
        return user.amount.mul(accEarnPerShare).div(1e12).sub(user.earnedDebt);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        if (pool.totalcap == 0 || pool.allocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = block.timestamp.sub(pool.lastRewardTime);
        uint256 singReward = multiplier.mul(singPerSec).mul(pool.allocPoint).div(totalAllocPoint);
        sing.mint(devaddr, singReward.div(10));
        sing.mint(address(this), singReward);
        pool.accSingPerShare = pool.accSingPerShare.add(singReward.mul(1e12).div(pool.totalcap));
        pool.lastRewardTime = block.timestamp;
    }
    function updateReward(uint _pid,uint _added) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if(_added>0 && pool.totalcap>0){
            safeEarnTransfer(devaddr, _added.mul(pool.earnfee).div(100));
            uint added=_added.sub(_added.mul(pool.earnfee).div(100));
            pool.accEarnPerShare=pool.accEarnPerShare.add(added.mul(1e12).div(pool.totalcap));
        }
    }

    function deposit(uint256 _pid, uint256 _amount) public nonReentrant{
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accSingPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeSingTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if(pool.depositFeeBP > 0){
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                uint256 finalamt=_amount.sub(depositFee);
                stratDeposit(_pid, finalamt);
                user.amount = user.amount.add(finalamt);
                pool.totalcap=pool.totalcap.add(finalamt);
            }else{
                stratDeposit(_pid, _amount);
                user.amount = user.amount.add(_amount);
                pool.totalcap=pool.totalcap.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accSingPerShare).div(1e12);
        user.earnedDebt=user.amount.mul(pool.accEarnPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant{
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        stratWithdraw(_pid, _amount);
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accSingPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeSingTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalcap=pool.totalcap.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSingPerShare).div(1e12);
        user.earnedDebt=user.amount.mul(pool.accEarnPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }
    function buybackSing(address _dual,uint _before) internal {
        //only in Joe with dual rewards, buyback and burn SING with the extra rewards
        address[] memory path = new address[](3);
        path[0] = _dual;
        path[1] = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;//wAVAX
        path[2] = address(sing);
        uint dualBal=IBEP20(_dual).balanceOf(address(this)).sub(_before);
        if(dualBal>0){
            if(IBEP20(_dual).allowance(address(this),address(JoeRouter))<dualBal){
                IBEP20(_dual).approve(address(JoeRouter), uint(-1));
            }
            JoeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                dualBal,
                0,
                path,
                address(0x000000000000000000000000000000000000dEaD),
                block.timestamp
            );
        }
    }
    function stratDeposit(uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (pool.isStrat) {
            if (pool.lpToken.allowance(address(this), address(WL_master)) < uint(-1)) {
                pool.lpToken.approve(address(WL_master), uint(-1));
            }
            uint preharvest=WL_earn.balanceOf(address(this));
            (address dual,)=WL_master.rewarderBonusTokenInfo(_pid);
            uint pre_dual;
            if(dual!=address(0)){
                pre_dual=IBEP20(dual).balanceOf(address(this));
            }
            WL_master.deposit(pool.stratId, _amount);
            if(dual!=address(0)){
                buybackSing(dual, pre_dual);
            }
            updateReward(_pid, WL_earn.balanceOf(address(this)).sub(preharvest));
            if(user.amount>0){
                uint256 pending=user.amount.mul(pool.accEarnPerShare).div(1e12).sub(user.earnedDebt);
                if(pending>0){
                    safeEarnTransfer(msg.sender, pending);
                }
            }
        }
    }
    function stratWithdraw(uint _pid,uint _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (pool.isStrat) {
            uint preharvest=WL_earn.balanceOf(address(this));
            (address dual,)=WL_master.rewarderBonusTokenInfo(_pid);
            uint pre_dual;
            if(dual!=address(0)){
                pre_dual=IBEP20(dual).balanceOf(address(this));
            }
            WL_master.withdraw(pool.stratId, _amount);
            if(dual!=address(0)){
                buybackSing(dual, pre_dual);
            }
            updateReward(_pid, WL_earn.balanceOf(address(this)).sub(preharvest));
            if(user.amount>0){
                uint256 pending=user.amount.mul(pool.accEarnPerShare).div(1e12).sub(user.earnedDebt);
                if(pending>0){
                    safeEarnTransfer(msg.sender, pending);
                }
            }
        }
    }
     // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant{
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        if (pool.isStrat) {
            uint preharvest=WL_earn.balanceOf(address(this));
            (address dual,)=WL_master.rewarderBonusTokenInfo(_pid);
            uint pre_dual;
            if(dual!=address(0)){
                pre_dual=IBEP20(dual).balanceOf(address(this));
            }
            WL_master.withdraw(pool.stratId, amount);
            if(dual!=address(0)){
                buybackSing(dual, pre_dual);
            }
            updateReward(_pid, WL_earn.balanceOf(address(this)).sub(preharvest));
        }
        pool.totalcap=pool.totalcap.sub(amount);
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function safeSingTransfer(address _to, uint256 _amount) internal {
        uint256 singBal = sing.balanceOf(address(this));
        if (_amount > singBal) {
            sing.transfer(_to, singBal);
            sing.mint(_to,_amount.sub(singBal));
        } else {
            sing.transfer(_to, _amount);
        }
    } 
    function safeEarnTransfer(address _to,uint256 _amount) internal {
        uint256 earnBal=WL_earn.balanceOf(address(this));
        if(_amount>earnBal){
            WL_earn.transfer(_to, earnBal);
        }else{
            WL_earn.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function setFeeAddress(address _feeAddress) public{
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _singPerSec) public onlyOwner {
        require(_singPerSec<1 ether,"too large");
        massUpdatePools();
        singPerSec = _singPerSec;
    }
}
