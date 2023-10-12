// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {MintBurnToken} from "./MintBurnToken.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {ICompounder} from "./interfaces/ICompounder.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";

// This contract accepts user deposits and withdrawals of a specific token.
// The deposits are redirected to an external protocol to generate yield.
// Yield is claimed and collected into this contract.
// Users accrue creditLine points over time while staking their tokens.
// CreditLine can be exchanged against the PSM token using the internal "Liquidity Pool".
// The contract can receive PSM tokens during the funding phase and issues receipt tokens. (bToken)
// bTokens can be redeemed against the fundingRewardPool which consists of PSM tokens.
// The fundingRewardPool is filled over time by taking a 10% cut from the Converter.
// The Converter is an arbitrage mechanism that allows anyone to sweep the contract balance of a token.
// When triggering the Converter, the arbitrager must send a fixed amount of PSM tokens to the contract.
contract Portal is ReentrancyGuard {
    constructor(uint256 _fundingPhaseDuration, 
        uint256 _fundingExchangeRatio,
        uint256 _fundingRewardRate, 
        address _principalToken, 
        address _bToken, 
        address _portalEnergy, 
        address _tokenToAcquire, 
        uint256 _terminalMaxLockDuration, 
        uint256 _amountToConvert)
        {
            fundingPhaseDuration = _fundingPhaseDuration;
            fundingExchangeRatio = _fundingExchangeRatio;
            fundingRewardRate = _fundingRewardRate;
            principalToken = _principalToken;
            bToken = _bToken;
            portalEnergy = _portalEnergy;
            tokenToAcquire = _tokenToAcquire;
            terminalMaxLockDuration = _terminalMaxLockDuration;
            amountToConvert = _amountToConvert;
            creationTime = block.timestamp;
    }

    // ============================================
    // ==        GLOBAL VARIABLES & EVENTS       ==
    // ============================================
    using SafeERC20 for IERC20;

    // general
    address immutable public bToken;                        // address of the bToken which is the receipt token from bootstrapping
    address immutable public portalEnergy;                  // address of PortalEnergy, the ERC20 representation of creditLine
    address immutable public tokenToAcquire;                // address of PSM token
    uint256 immutable public amountToConvert;               // constant amount of PSM tokens required to withdraw yield in the contract
    uint256 immutable public terminalMaxLockDuration;       // terminal maximum lock duration of user´s balance in seconds
    uint256 immutable public creationTime;                  // time stamp of deployment
    uint256 constant private secondsPerYear = 31536000;     // seconds in a 365 day year
    uint256 public maxLockDuration = 7776000;               // starting value for maximum allowed lock duration of user´s balance in seconds (90 days)
    uint256 public totalPrincipalStaked;                    // shows how much principal is staked by all users combined
    bool private lockDurationUpdateable = true;             // flag to signal if the lock duration can still be updated

    // principal management related
    address immutable public principalToken;                // address of the token accepted by the strategy as deposit (HLP)
    address payable private constant compounderAddress = payable (0x8E5D083BA7A46f13afccC27BFB7da372E9dFEF22);

    address payable private constant HLPstakingAddress = payable (0xbE8f8AF5953869222eA8D39F1Be9d03766010B1C);
    address private constant HLPprotocolRewarder = 0x665099B3e59367f02E5f9e039C3450E31c338788;
    address private constant HLPemissionsRewarder = 0x6D2c18B559C5343CB0703bB55AADB5f22152cC32;

    address private constant HMXstakingAddress = 0x92E586B8D4Bf59f4001604209A292621c716539a;
    address private constant HMXprotocolRewarder = 0xB698829C4C187C85859AD2085B24f308fC1195D3;
    address private constant HMXemissionsRewarder = 0x94c22459b145F012F1c6791F2D729F7a22c44764;
    address private constant HMXdragonPointsRewarder = 0xbEDd351c62111FB7216683C2A26319743a06F273;

    // bootstrapping related
    uint256 immutable private fundingPhaseDuration;         // seconds that the funding phase lasts before Portal can be activated
    uint256 public fundingBalance;                          // sum of all PSM funding contributions
    uint256 public fundingRewardPool;                       // amount of PSM available for redemption against eTokens
    uint256 public fundingRewardsCollected;                 // tracker of PSM collected over time for the reward pool
    uint256 public fundingMaxRewards;                       // maximum amount of PSM to be collected for reward pool
    uint256 immutable public fundingRewardRate;             // baseline return on funding the Portal
    uint256 immutable private fundingExchangeRatio;         // amount of creditLine per PSM for calculating k during funding process
    uint256 constant public fundingRewardShare = 10;        // 10% of yield goes to the funding pool until investors are paid back
    bool public isActivePortal = false;                     // this will be set to true when funding phase ends.

    // exchange related
    uint256 public constantProduct;                        // the K constant of the (x*y = K) constant product formula
    uint256 private reserve0;                              // reserve of PSM tokens for LP calculations
    uint256 private reserve1;                              // reserve of creditLine for LP calculations

    // user related
    struct Account {                                       // contains information of user stake positions
    bool isExist;
    uint256 lastUpdateTime;
    uint256 stakedBalance;
    uint256 maxStakeDebt;
    uint256 creditLine;
    uint256 availableToWithdraw;
    }

    mapping(address => Account) public accounts;            // Associate users with their stake position

    // Events related to the funding phase
    event PortalActivated(address indexed, uint256 fundingBalance);
    event FundingReceived(address indexed, uint256 amount);

    // Events related to internal exchange PSM vs. creditLine
    event CreditLineBuyExecuted(address indexed, uint256 amount);
    event CreditLineSellExecuted(address indexed, uint256 amount);

    // Events related to staking & unstaking
    event TokenStaked(address indexed user, uint256 amountStaked);
    event TokenUnstaked(address indexed user, uint256 amountUnstaked);
    event RewardsClaimed(address[] indexed pools, address[][] rewarders, uint256 timeStamp);

    event StakePositionUpdated(address indexed user, 
        uint256 lastUpdateTime,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 creditLine,
        uint256 availableToWithdraw);                       // principal available to withdraw

    // ============================================
    // ==           STAKING & UNSTAKING          ==
    // ============================================

    // Update user data to the current state. Only callable by the Portal
    function _updateAccount(address _user, uint256 _amount) private {
        // Calculate accrued creditLine since last update
        uint256 creditEarned = (accounts[_user].stakedBalance * 
            (block.timestamp - accounts[_user].lastUpdateTime)) / secondsPerYear;
      
        // Update the Last Update Time Stamp
        accounts[_user].lastUpdateTime = block.timestamp;

        // Update user staked balance
        accounts[_user].stakedBalance += _amount;

        // Update user maxStakeDebt
        accounts[_user].maxStakeDebt += (_amount * maxLockDuration) / secondsPerYear;

        // update user creditLine
        accounts[_user].creditLine += creditEarned;

        // Update amount available to unstake
        if (accounts[_user].creditLine >= accounts[_user].maxStakeDebt) {
            accounts[_user].availableToWithdraw = accounts[_user].stakedBalance;
        } else {
            accounts[_user].availableToWithdraw = (accounts[_user].stakedBalance * accounts[_user].creditLine) / accounts[_user].maxStakeDebt;
        }
    }


    // Stake the principal token into the Portal & redirect principal to yield source
    function stake(uint256 _amount) external nonReentrant {
        // Check if Portal has closed the funding phase and is active
        require(isActivePortal);
        
        // Transfer user principal tokens to the contract
        IERC20(principalToken).safeTransferFrom(msg.sender, address(this), _amount);
        
        // Update total stake balance
        totalPrincipalStaked += _amount;

        // Deposit principal into yield source (external protocol)
        _depositToYieldSource();

        // Check if user has a staking position, else initialize with this stake.
        if(accounts[msg.sender].isExist == true){
            // update the user´s stake info
            _updateAccount(msg.sender, _amount);
        } 
        else {
            uint256 maxStakeDebt = (_amount * maxLockDuration) / secondsPerYear;
            uint256 availableToWithdraw = _amount;
            uint256 creditLine = maxStakeDebt;
            
            accounts[msg.sender] = Account(true, 
                block.timestamp, 
                _amount, 
                maxStakeDebt, 
                creditLine,
                availableToWithdraw);     
        }
        
        // Emit event with updated stake information
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].creditLine, 
        accounts[msg.sender].availableToWithdraw);
    }


    // Serve unstaking requests & withdraw principal from yield source
    function unstake(uint256 _amount) external nonReentrant {
        // Check if user has a stake and update user stake data
        require(accounts[msg.sender].isExist == true,"User has no stake");
        _updateAccount(msg.sender,0);

        // Check if amount can be unstaked
        require(_amount <= accounts[msg.sender].availableToWithdraw, "Insufficient withdrawable balance");
        require(_amount <= accounts[msg.sender].stakedBalance, "Insufficient stake balance");

        // Withdraw matching amount of principal from yield source (external protocol)
        _withdrawFromYieldSource(_amount);

        // Update user stake balance
        accounts[msg.sender].stakedBalance -= _amount;

        // Update user maximum stake debt
        accounts[msg.sender].maxStakeDebt -= (_amount * maxLockDuration) / secondsPerYear;

        // Update user withdrawable balance
        accounts[msg.sender].availableToWithdraw -= _amount;

        // update the global tracker of staked principal
        totalPrincipalStaked -= _amount;

        // Send principal tokens to user
        IERC20(principalToken).safeTransfer(msg.sender, _amount);

        // Emit event with updated stake information
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].creditLine,
        accounts[msg.sender].availableToWithdraw);
    }


    // Force unstaking via burning PortalEnergy (token) from user wallet to decrease debt sufficiently to unstake all
    function forceUnstakeAll() external nonReentrant {
        // Check if user has a stake and update user stake data
        require(accounts[msg.sender].isExist == true,"User has no stake");
        _updateAccount(msg.sender,0);

        // Calculate how much PortalEnergy must be burned from user wallet, if any
        if(accounts[msg.sender].creditLine < accounts[msg.sender].maxStakeDebt) {

            uint256 remainingDebt = accounts[msg.sender].maxStakeDebt - accounts[msg.sender].creditLine;

            // burn appropriate PortalEnergy from user wallet to increase creditLine sufficiently
            require(IERC20(portalEnergy).balanceOf(address(msg.sender)) >= remainingDebt, "Not enough Portal Energy");
            _burnPortalEnergy(msg.sender, remainingDebt);
        }

        // Withdraw principal from yield source to pay user
        uint256 balance = accounts[msg.sender].stakedBalance;
        _withdrawFromYieldSource(balance);

        // Update user information
        accounts[msg.sender].stakedBalance = 0;
        accounts[msg.sender].maxStakeDebt = 0;
        accounts[msg.sender].creditLine -= (balance * maxLockDuration) / secondsPerYear;
        accounts[msg.sender].availableToWithdraw = 0;

        // Send full stake balance to user
        IERC20(principalToken).safeTransferFrom(msg.sender, address(this), balance);
        totalPrincipalStaked -= balance;

        // Emit event with updated stake information
        emit StakePositionUpdated(msg.sender, 
        accounts[msg.sender].lastUpdateTime,
        accounts[msg.sender].stakedBalance,
        accounts[msg.sender].maxStakeDebt, 
        accounts[msg.sender].creditLine,
        accounts[msg.sender].availableToWithdraw);
    }

    // ============================================
    // ==      PRINCIPAL & REWARD MANAGEMENT     ==
    // ============================================

    // Deposit principal into yield source
    function _depositToYieldSource() private {
        // Read how many principalTokens are in the contract and approve this amount
        uint256 balance = IERC20(principalToken).balanceOf(address(this));
        IERC20(principalToken).approve(HLPstakingAddress, balance);

        // transfer the approved balance to the external protocol using the interface
        IStaking(HLPstakingAddress).deposit(address(this), balance);

        // emit Event that tokens have been staked for the user
        emit TokenStaked(msg.sender, balance);
    }


    // Withdraw principal from yield source into this contract
    function _withdrawFromYieldSource(uint256 _amount) private {

        // withdraw the staked balance from external protocol using the interface
        IStaking(HLPstakingAddress).withdraw(_amount);

        // emit Event that tokens have been unstaked for the user
        emit TokenUnstaked(msg.sender, _amount);
    }


    // Claim rewards related to HLP and HMX staked by this contract
    function claimRewardsHLPandHMX() external {
        // generate & fill the first input array for the compounder        
        address[] memory pools = new address[](2);
        pools[0] = HLPstakingAddress;
        pools[1] = HMXstakingAddress;

        // generate & fill the second input array for the compounder       
        address[][] memory rewarders = new address[][](2);
        rewarders[0] = new address[](2);
        rewarders[0][0] = HLPprotocolRewarder;
        rewarders[0][1] = HLPemissionsRewarder;

        rewarders[1] = new address[](3);
        rewarders[1][0] = HMXprotocolRewarder;
        rewarders[1][1] = HMXemissionsRewarder;
        rewarders[1][2] = HMXdragonPointsRewarder;

        // claim rewards from HLP and HMX staking via the interface
        // esHMX and DP are staked automatically, USDC transferred to contract
        ICompounder(compounderAddress).compound(
            pools,
            rewarders,
            1689206400,
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            new uint256[](0)
        );

        // Emit event that rewards have been claimed
        emit RewardsClaimed(pools, rewarders, block.timestamp);
    }


    // If the above claim function breaks in the future, use this function to claim specific rewards
    function claimRewardsManual(address[] memory _pools, address[][] memory _rewarders) external {
        // claim rewards from any staked token and any rewarder via interface
        // esHMX and DP are staked automatically, USDC or other reward token transferred to contract
        ICompounder(compounderAddress).compound(
            _pools,
            _rewarders,
            1689206400,
            115792089237316195423570985008687907853269984665640564039457584007913129639935,
            new uint256[](0)
        );

        //Emit event that rewards have been claimed
        emit RewardsClaimed(_pools, _rewarders, block.timestamp);
    }

    // ============================================
    // ==               INTERNAL LP              ==
    // ============================================

    // Sell PSM into contract to top up creditLine balance
    function buyCreditLine(uint256 _amountInput, uint256 _minReceived) external nonReentrant {
        // Check if user has a stake and update stake data
        require(accounts[msg.sender].isExist == true,"User has no stake");
        _updateAccount(msg.sender,0);

        // Check if user has enough input tokens
        require(IERC20(tokenToAcquire).balanceOf(msg.sender) >= _amountInput, "Insufficient balance");
        
        // Update inputToken reserve
        reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        // Calculate reserve of creditLine (Output)
        reserve1 = constantProduct / reserve0;

        // Calculate amount of creditLine received
        uint256 amountReceived = (_amountInput * reserve1) / (_amountInput + reserve0);

        // Check if amount at least matches expected output
        require(amountReceived >= _minReceived, "Output too small");

        // transfer input tokens from user to contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), _amountInput);

        // Increase creditLine of user
        accounts[msg.sender].creditLine += amountReceived;

        // emit event that swap was successful
        emit CreditLineBuyExecuted(msg.sender, amountReceived);
    }


    function sellCreditLine(uint256 _amountInput, uint256 _minReceived) external nonReentrant {
        // Check if user has a stake and update stake data
        require(accounts[msg.sender].isExist == true,"User has no stake");
        _updateAccount(msg.sender,0);
        
        // Check if user has enough creditLine to sell
        require(accounts[msg.sender].creditLine >= _amountInput, "Insufficient balance");

        // Update outputToken reserve
        reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        // Calculate reserve of creditLine (Input)
        reserve1 = constantProduct / reserve0;

        // Calculate amount of outputToken received
        uint256 amountReceived = (_amountInput * reserve0) / (_amountInput + reserve1);

        // Check if amount at least matches expected output
        require(amountReceived >= _minReceived, "Output too small");

        // reduce creditLine balance of user
        accounts[msg.sender].creditLine -= _amountInput;

        // send outputToken to user
        IERC20(tokenToAcquire).safeTransfer(msg.sender, amountReceived);

        // emit event that swap was successful
        emit CreditLineSellExecuted(msg.sender, _amountInput);
    }

    // ============================================
    // ==              PSM CONVERTER             ==
    // ============================================

    // handle the arbitrage conversion of tokens inside the contract for PSM tokens
    function convert(address _token, uint256 _minReceived) external nonReentrant {

        // Check that the output token is not the input or stake token (PSM / HLP)
        require(_token != tokenToAcquire, "Cannot receive the input token");
        require(_token != principalToken, "Cannot receive the stake token");

        // Check if sufficient output token is available in the contract (frontrun protection)
        uint256 contractBalance = IERC20(_token).balanceOf(address(this));
        require (contractBalance >= _minReceived, "Not enough tokens in contract");

        // Transfer input (PSM) token from user to contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), amountToConvert); 

        // update funding reward pool balance and the tracker of collected rewards
        if (IERC20(bToken).totalSupply() > 0 && fundingRewardsCollected < fundingMaxRewards) {
            uint256 newRewards = (fundingRewardShare * amountToConvert) / 100;
            fundingRewardPool += newRewards;
            fundingRewardsCollected += newRewards;
        }

        // update reserve0 (PSM) to keep internal exchange price accurate
        reserve0 = IERC20(tokenToAcquire).balanceOf(address(this)) - fundingRewardPool;

        // Transfer output token from contract to user
        IERC20(_token).safeTransfer(msg.sender, contractBalance);
    }

    // ============================================
    // ==              BOOTSTRAPPING             ==
    // ============================================
    
    // Allow users to deposit PSM to provide initial upfront yield
    // Contract MUST BE OWNER of the specific eToken to work
    function contributeFunding(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(isActivePortal == false,"Funding phase concluded");

        // increase the funding tracker balance
        fundingBalance += _amount;

        // calculate the amount of bTokens to be minted
        uint256 mintableAmount = _amount * fundingRewardRate;

        // transer PSM to Contract
        IERC20(tokenToAcquire).safeTransferFrom(msg.sender, address(this), _amount); 

        // mint eToken to user
        MintBurnToken(bToken).mint(msg.sender, mintableAmount);

        // emit event that funding was received
        emit FundingReceived(msg.sender, mintableAmount);
    }


    // Calculate the current burn value of amount eTokens. Return value is amount PSM tokens
    function getBurnValuePsm(uint256 _amount) public view returns(uint256 burnValue) {
        burnValue = (fundingRewardPool * _amount) / IERC20(bToken).totalSupply();
        return burnValue;
    }


    // Burn user eTokens to receive PSM
    function burnEtokens(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(isActivePortal = true, "Portal not active");

        // calculate how many PSM user receives
        uint256 amountToReceive = getBurnValuePsm(_amount);

        // burn eTokens from user
        MintBurnToken(bToken).burnFrom(msg.sender, _amount);

        // reduce funding reward pool by amount of PSM payable to user
        fundingRewardPool -= amountToReceive;

        // transfer PSM to user
        IERC20(tokenToAcquire).safeTransfer(msg.sender, amountToReceive);
    }


    // End the funding phase and enable normal contract functionality
    function activatePortal() external {
        require(isActivePortal = false, "Portal already active");
        require(block.timestamp >= creationTime + fundingPhaseDuration,"Funding phase ongoing");

        // calculate the amount of creditLine to match the funding amount in internal LP
        uint256 requiredCreditLiquidity = fundingBalance * fundingExchangeRatio;
        
        // set the constant product K
        constantProduct = fundingBalance * requiredCreditLiquidity;

        // calculate the maximum rewards to be collected
        fundingMaxRewards = IERC20(bToken).totalSupply();

        // activate the Portal and emit event   
        isActivePortal = true;
        emit PortalActivated(address(this), fundingBalance);
    }

    // ============================================
    // ==           GENERAL FUNCTIONS            ==
    // ============================================
    
    // Mint portal energy tokens to recipient and decrease creditLine of caller equally
    // Contract must be owner of the PortalEnergy Token
    function storePortalEnergy(address _recipient, uint256 _amount) external nonReentrant {   
        // Check if caller has sufficient creditLine
        require(accounts[msg.sender].creditLine >= _amount, "Insufficient credit line");

        // decrease the creditLine of caller
        accounts[msg.sender].creditLine -= _amount;

        // mint tokens to recipient wallet
        MintBurnToken(portalEnergy).mint(_recipient, _amount);
    }


    // Burn portal energy tokens from user wallet and increase creditLine of recipient equally
    function burnPortalEnergy(address _recipient, uint256 _amount) external nonReentrant {   
        // Check if recipient has a stake position
        require(accounts[_recipient].isExist == true);

        // burn tokens from caller wallet
        MintBurnToken(portalEnergy).burnFrom(msg.sender, _amount);

        // increase the creditLine of recipient
        accounts[_recipient].creditLine += _amount;
    }


    // Burn portal energy tokens from user wallet and increase creditLine of user equally
    function _burnPortalEnergy(address _user, uint256 _amount) private {   
        // Check if user has a stake position
        require(accounts[_user].isExist == true);

        // burn tokens from caller wallet
        MintBurnToken(portalEnergy).burnFrom(_user, _amount);

        // increase the creditLine of user
        accounts[_user].creditLine += _amount;
    }


    // update the maximum lock duration up to the terminal value
    function updateMaxLockDuration() external {
        require(lockDurationUpdateable == true,"Lock duration cannot increase");

        uint256 newValue = 2 * (block.timestamp - creationTime);

        if (newValue >= terminalMaxLockDuration) {
            maxLockDuration = terminalMaxLockDuration;
            lockDurationUpdateable = false;
        } 
        else if (newValue > maxLockDuration) {
            maxLockDuration = newValue;
        }
    }


    // Simulate updating a user stake position and return the values without updating the struct
    function getUpdateAccount(address _user, uint256 _amount) public view returns(
        address user,
        uint256 lastUpdateTime,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 creditLine,
        uint256 availableToWithdraw) {

        // Calculate accrued creditLine since last update
        uint256 creditEarned = (accounts[_user].stakedBalance * 
            (block.timestamp - accounts[_user].lastUpdateTime)) / secondsPerYear;
      
        // Get the current Time Stamp
        lastUpdateTime = block.timestamp;

        // calculate user staked balance
        stakedBalance = accounts[_user].stakedBalance + _amount;

        // Update user maxStakeDebt
        maxStakeDebt = accounts[_user].maxStakeDebt + (_amount * maxLockDuration) / secondsPerYear;

        // update user creditLine
        creditLine = accounts[_user].creditLine + creditEarned;

        // Update amount available to unstake
        if (creditLine >= maxStakeDebt) {
            availableToWithdraw = stakedBalance;
        } else {
            availableToWithdraw = (stakedBalance * creditLine) / maxStakeDebt;
        }

    return (_user, lastUpdateTime, stakedBalance, maxStakeDebt, creditLine, availableToWithdraw);
    }


    // Simulate forced unstake and return the number of portal energy tokens to be burned      
    function quoteforceUnstakeAll(address _user) public view returns(uint256 portalEnergyToBurn) {

        // get relevant data from simulated account update
        (, , , uint256 maxStakeDebt, uint256 creditLine,) = getUpdateAccount(_user,0);

        // Calculate how many portal energy tokens must be burned
        if(maxStakeDebt > creditLine) {
            portalEnergyToBurn = maxStakeDebt - creditLine;
        }

        // return amount of portal energy to be burned for full unstake
        return portalEnergyToBurn; 
    }


    // View balance of tokens inside the contract
    function getBalanceOfToken(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }


    // View claimable yield from a specific rewarder contract of the yield source
    function getPendingRewards(address _rewarder) public view returns(uint256 claimableReward){

        claimableReward = IRewarder(_rewarder).pendingReward(address(this));

        return(claimableReward);
    }
}
