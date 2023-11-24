// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {Portal} from "../../contracts/Portal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MintBurnToken} from "../mocks/MintToken.sol";
import {IHLP} from "../mocks/IHLP.sol";


//forge test --fork-url https://arbitrum-mainnet.infura.io/v3/<> --fork-block-number 153000000 
//
contract PortalTest is Test {

    // addresses
    address private constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;
    address private constant PRINCIPAL_TOKEN_ADDRESS = 0x4307fbDCD9Ec7AEA5a1c2958deCaa6f316952bAb;
    address private constant HLP_STAKING = 0x4307fbDCD9Ec7AEA5a1c2958deCaa6f316952bAb;
    address private constant HLP_PROTOCOL_REWARDER = 0x665099B3e59367f02E5f9e039C3450E31c338788;
    address private constant HLP_EMISSIONS_REWARDER = 0x6D2c18B559C5343CB0703bB55AADB5f22152cC32;
    address private constant HMX_STAKING = 0x92E586B8D4Bf59f4001604209A292621c716539a;
    address private constant HMX_PROTOCOL_REWARDER = 0xB698829C4C187C85859AD2085B24f308fC1195D3;
    address private constant HMX_EMISSIONS_REWARDER = 0x94c22459b145F012F1c6791F2D729F7a22c44764;
    address private constant HMX_DRAGONPOINTS_REWARDER = 0xbEDd351c62111FB7216683C2A26319743a06F273;

    // constant values
    uint256 constant _FUNDING_PHASE_DURATION = 432000;
    uint256 constant _FUNDING_EXCHANGE_RATIO = 550;
    uint256 constant _FUNDING_REWARD_RATE = 10;
    uint256 constant _TERMINAL_MAX_LOCK_DURATION = 157680000;  
    uint256 constant _AMOUNT_TO_CONVERT  = 100000*1e18;
    uint256 constant private SECONDS_PER_YEAR = 31536000;   // seconds in a 365 day year
    uint256 public maxLockDuration = 7776000;               // 7776000 starting value for maximum allowed lock duration of user´s balance in seconds (90 days)
    uint256 constant private _DECIMALS = 1e18;
    uint256 constant private _TRADE_TIMELOCK = 60;

    // portal
    Portal public portal;

    // time
    uint256 timestamp;
    uint256 timeAfterActivating;

    // prank addresses
    address Alice = address(0x1);
    address Bob = address(0x002);

    // tokens
    MintBurnToken bToken = new MintBurnToken("BT","BT");
    MintBurnToken eToken = new MintBurnToken("BT","BT");
    
    // ============================================
    // ==               CUSTOM EVENT             ==
    // ============================================

    // --- Events related to the funding phase ---
    event PortalActivated(address indexed, uint256 fundingBalance);
    event FundingReceived(address indexed, uint256 amount);
    event RewardsRedeemed(address indexed, uint256 amountBurned, uint256 amountReceived);

    // --- Events related to internal exchange PSM vs. portalEnergy ---
    event PortalEnergyBuyExecuted(address indexed, uint256 amount);
    event PortalEnergySellExecuted(address indexed, uint256 amount);

    // --- Events related to minting and burning portalEnergyToken ---
    event PortalEnergyMinted(address indexed, address recipient, uint256 amount);
    event PortalEnergyBurned(address indexed, address recipient, uint256 amount);

    // --- Events related to staking & unstaking ---
    event TokenStaked(address indexed user, uint256 amountStaked);
    event TokenUnstaked(address indexed user, uint256 amountUnstaked);
    event RewardsClaimed(address[] indexed pools, address[][] rewarders, uint256 timeStamp);

    event StakePositionUpdated(address indexed user, 
        uint256 lastUpdateTime,
        uint256 lastMaxLockDuration,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy,
        uint256 availableToWithdraw);           

    // ============================================
    // ==          CUSTOM ERROR MESSAGES         ==
    // ============================================
    error DeadlineExpired();
    error PortalNotActive();
    error PortalAlreadyActive();
    error AccountDoesNotExist();
    error InsufficientToWithdraw();
    error InsufficientStake();
    error InsufficientPEtokens();
    error InsufficientBalance();
    error InvalidOutput();
    error InvalidInput();
    error InvalidToken();
    error FundingPhaseOngoing();
    error DurationLocked();
    error DurationCannotIncrease();
    error TradeTimelockActive();
    error FailedToSendNativeToken();

    function setUp() public {
        portal = new Portal(
            _FUNDING_PHASE_DURATION, 
            _FUNDING_EXCHANGE_RATIO,
            _FUNDING_REWARD_RATE,
            PRINCIPAL_TOKEN_ADDRESS,
            _DECIMALS,
            PSM_ADDRESS,
            address(bToken),
            address(eToken),
            _TERMINAL_MAX_LOCK_DURATION,
            _AMOUNT_TO_CONVERT,
            _TRADE_TIMELOCK
            );

        // creation time
        timestamp = block.timestamp;
        timeAfterActivating = timestamp + _FUNDING_PHASE_DURATION;

        // bToken, ENERGY Token
        bToken.transferOwnership(address(portal));
        eToken.transferOwnership(address(portal));

        // PSM TOKEN
        address PSMWale = 0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33;
        vm.startPrank(PSMWale);
        IERC20(PSM_ADDRESS).transfer(address(this), 1e25);

        // PT TOKEN
        address PTOwner = 0x6409ba830719cd0fE27ccB3051DF1b399C90df4a;
        vm.startPrank(PTOwner);
        IHLP(PRINCIPAL_TOKEN_ADDRESS).setMinter(address(this), true);
        vm.stopPrank();
        IHLP(PRINCIPAL_TOKEN_ADDRESS).mint(address(this), 1e25);

        // distribute tokens
        IERC20(PSM_ADDRESS).transfer(address(Alice), 1e20);
        IERC20(PSM_ADDRESS).transfer(address(Bob), 1e20);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).transfer(address(Alice), 1e20);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).transfer(address(Bob), 1e20);
    }

    // ---------------------------------------------------
    // --------------------funding------------------------
    // ---------------------------------------------------

    // reverts
    function testRevert_funding0Amount() public{
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e5);
        vm.expectRevert(InvalidInput.selector);
        portal.contributeFunding(0);
    }
    function testRevert_fundingActivePortal() public{
        vm.warp(timestamp + 432001);
        portal.activatePortal();
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e5);
        vm.expectRevert(PortalAlreadyActive.selector);
        portal.contributeFunding(1e5);
    }

    // event
    function testEvent_funding() public {
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e5);
        vm.expectEmit(address(portal));
        emit FundingReceived(address(Alice), 1e5*10);
        portal.contributeFunding(1e5);
    }

    // funding
    function test_funding() public {
        vm.startPrank(Alice);
        assertEq(portal.fundingBalance(), 0);
        assertEq(bToken.totalSupply(), 0);
        assertEq(bToken.balanceOf(address(Alice)), 0);
        IERC20(PSM_ADDRESS).approve(address(portal), 2e5);
        portal.contributeFunding(1e5);
        assertEq(portal.fundingBalance(), 1e5);
        assertEq(bToken.totalSupply(), 1e5*10);
        assertEq(bToken.balanceOf(address(Alice)), 1e5*10);
        portal.contributeFunding(1e5);
        assertEq(portal.fundingBalance(), 1e5*2);
        assertEq(bToken.totalSupply(), 1e5*2*10);
        assertEq(bToken.balanceOf(address(Alice)), 1e5*2*10);
    }

    // ---------------------------------------------------
    // --------------------activating---------------------
    // ---------------------------------------------------

    // reverts
    function testRevert_activatePortalTwice() public{
        vm.warp(timestamp + 432001);
        portal.activatePortal();
        vm.expectRevert(PortalAlreadyActive.selector);
        portal.activatePortal();
    }
    function testRevert_beforeFundingPhaseEnded() public{
        vm.expectRevert(FundingPhaseOngoing.selector);
        portal.activatePortal();
    }

    // events
    function testEvent_activateProtal() public{
        vm.warp(timestamp + 432001);
        vm.expectEmit(address(portal));
        emit PortalActivated(address(portal), 0);
        portal.activatePortal();
    }

    // activating
    function test_activating() public {
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e5);
        portal.contributeFunding(1e5);
        assertEq(portal.isActivePortal(), false);
        assertEq(portal.fundingMaxRewards(), 0);
        assertEq(portal.constantProduct(), 0);
        assertEq(portal.fundingBalance(), 1e5);
        vm.warp(timestamp + 432001);
        portal.activatePortal();
        assertEq(portal.isActivePortal(), true);
        assertEq(portal.fundingMaxRewards(), 1e5*10);
        assertEq(portal.constantProduct(), 18181818); //1e5*1e5/550
        assertEq(portal.fundingBalance(), 1e5);
    }

    // ---------------------------------------------------
    // ------------------maxlockduraion-------------------
    // ---------------------------------------------------

    // reverts
    function testRevert_newTimeLessThanMaxlockduraion() external{
        vm.warp(timestamp);
        vm.expectRevert(DurationCannotIncrease.selector);
        portal.updateMaxLockDuration();
    }
    function testRevert_lockDurationNotUpdateable() external{
        vm.warp(timestamp + 365*6 days);
        portal.updateMaxLockDuration();
        vm.expectRevert(DurationLocked.selector);
        portal.updateMaxLockDuration();
    }

    // updateMaxLockDuration
    function test_updateMaxLockDuration() external{
        assertEq(portal.maxLockDuration(), maxLockDuration);
        vm.warp(timestamp + maxLockDuration + 1);
        portal.updateMaxLockDuration(); 
        assertEq(portal.maxLockDuration(), 2*(timestamp + maxLockDuration + 1 - portal.CREATION_TIME()));
        vm.warp(timestamp + 365 * 5 days);
        portal.updateMaxLockDuration(); 
        assertEq(portal.maxLockDuration(), _TERMINAL_MAX_LOCK_DURATION);        
    }

    /////////////////////////////////////////////////////////// helper
    function help_fundAndActivate() internal {
        vm.startPrank(Alice);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e18);
        portal.contributeFunding(1e18);
        vm.startPrank(Bob);
        IERC20(PSM_ADDRESS).approve(address(portal), 1e18);
        portal.contributeFunding(1e18);
        vm.warp(timeAfterActivating);
        portal.activatePortal();
        vm.stopPrank();
    }
    function help_stake() internal {
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e18);
        vm.startPrank(Bob);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------
    // ---------------staking and unstaking---------------
    // ---------------------------------------------------

    // reverts
    function testRevert_stakePortalNotActive() external {
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        vm.expectRevert(PortalNotActive.selector);
        portal.stake(1e5);
    }
    function testRevert_stake0Amount() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        vm.expectRevert(InvalidInput.selector);
        portal.stake(0);
    }
    function testRevert_unStakeExistingAccount() external {
        vm.startPrank(Alice);
        vm.expectRevert(AccountDoesNotExist.selector);
        portal.unstake(1e5);
    }
    function testRevert_unStake0Amount() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InvalidInput.selector);
        portal.unstake(0);
    }
    function testRevert_unStakeMoreThanStaked() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert(InsufficientToWithdraw.selector);
        portal.unstake(1e19);
    }
    function testRevert_forceunStakeExistingAccount() external {
        vm.startPrank(Alice);
        vm.expectRevert(AccountDoesNotExist.selector);
        portal.forceUnstakeAll();
    }

    // events
    function testEvent_stake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(address(Alice), 
        block.timestamp,
        maxLockDuration,
        1e5,
        1e5*maxLockDuration/SECONDS_PER_YEAR,
        1e5*maxLockDuration/SECONDS_PER_YEAR,
        1e5);
        portal.stake(1e5);
    }
    function testEvent_reStake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(address(Alice), 
        block.timestamp,
        maxLockDuration,
        1e5,
        1e5*maxLockDuration/SECONDS_PER_YEAR,       //100000*7776000/31536000=24657
        1e5*maxLockDuration/SECONDS_PER_YEAR,       //24657
        1e5);
        portal.stake(1e5);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(address(Alice), 
        block.timestamp,                            //lastUpdateTime 1701103606
        maxLockDuration,                            //maxLockDuration 7776000
        1e5*2,                                      //stakedBalance 200000
        1e5*2*maxLockDuration/SECONDS_PER_YEAR,     //maxStakeDebt 49315 
        1e5*2*maxLockDuration/SECONDS_PER_YEAR - 1, //portalEnergy 49314
        199995);                                    //availableToWithdraw 199995
        portal.stake(1e5);
    }
    function testEvent_unStake() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(address(Alice), 
        block.timestamp,
        maxLockDuration,
        0,
        0,
        0,
        0);
        portal.unstake(1e18);
    }
    function testEvent_unStakePartially() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(address(Alice), 
        block.timestamp,
        maxLockDuration,
        5e17,
        5e17*maxLockDuration/SECONDS_PER_YEAR,
        5e17*maxLockDuration/SECONDS_PER_YEAR,
        5e17);
        portal.unstake(5e17);
    }
    function testEvent_forceunStake() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(address(Alice), 
        block.timestamp,
        maxLockDuration,
        0,
        0,
        0,
        0);
        portal.forceUnstakeAll();
    }
    function testEvent_forceunStakeWithExtraEnergy() external {
        help_fundAndActivate();
        help_stake();
        vm.warp(timeAfterActivating + 60);
        vm.startPrank(Alice);
        vm.expectEmit(address(portal));
        emit StakePositionUpdated(address(Alice), 
        block.timestamp,
        maxLockDuration,
        0,
        0, //
        1902587519025, //1902587519025 = 60 * 1e18 / 31536000 
        0);
        portal.unstake(1e18);
    }

        // (, , , , , portalEnergy,) = portal.getUpdateAccount(address(Alice),0); /// UNTILL HERE
        // console2.log(portalEnergy);

    // stake
    function test_stake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        (address user,
        uint256 lastUpdateTime,
        uint256 lastMaxLockDuration,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy,
        uint256 availableToWithdraw) = portal.getUpdateAccount(address(Alice), 0 );
        assertEq(user, address(Alice));
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(lastMaxLockDuration, maxLockDuration);
        assertEq(stakedBalance, 1e5);
        assertEq(maxStakeDebt, 1e5*maxLockDuration/SECONDS_PER_YEAR);
        assertEq(portalEnergy, 1e5*maxLockDuration/SECONDS_PER_YEAR);
        assertEq(availableToWithdraw, 1e5);
    }
    function test_restake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        (address user,
        uint256 lastUpdateTime,
        uint256 lastMaxLockDuration,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy,
        uint256 availableToWithdraw) = portal.getUpdateAccount(address(Alice), 0 );
        assertEq(user, address(Alice));
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(lastMaxLockDuration, maxLockDuration);
        assertEq(stakedBalance, 1e5);
        assertEq(maxStakeDebt, 1e5*maxLockDuration/SECONDS_PER_YEAR);
        assertEq(portalEnergy, 1e5*maxLockDuration/SECONDS_PER_YEAR);
        assertEq(availableToWithdraw, 1e5);
    }
    function test_unstake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        (address user,
        uint256 lastUpdateTime,
        uint256 lastMaxLockDuration,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy,
        uint256 availableToWithdraw) = portal.getUpdateAccount(address(Alice), 0 );
        assertEq(user, address(Alice));
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(lastMaxLockDuration, maxLockDuration);
        assertEq(stakedBalance, 1e5);
        assertEq(maxStakeDebt, 1e5*maxLockDuration/SECONDS_PER_YEAR);
        assertEq(portalEnergy, 1e5*maxLockDuration/SECONDS_PER_YEAR);
        assertEq(availableToWithdraw, 1e5);
    }
    function test_forceunstake() external {
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        (address user,
        uint256 lastUpdateTime,
        uint256 lastMaxLockDuration,
        uint256 stakedBalance,
        uint256 maxStakeDebt,
        uint256 portalEnergy,
        uint256 availableToWithdraw) = portal.getUpdateAccount(address(Alice), 0 );
        assertEq(user, address(Alice));
        assertEq(lastUpdateTime, block.timestamp);
        assertEq(lastMaxLockDuration, maxLockDuration);
        assertEq(stakedBalance, 1e5);
        assertEq(maxStakeDebt, 1e5*maxLockDuration/SECONDS_PER_YEAR);
        assertEq(portalEnergy, 1e5*maxLockDuration/SECONDS_PER_YEAR);
        assertEq(availableToWithdraw, 1e5);
    }

    function testtest() external{
        help_fundAndActivate();
        vm.startPrank(Alice);
        IERC20(PRINCIPAL_TOKEN_ADDRESS).approve(address(portal), 1e18);
        portal.stake(1e5);
        console2.log("user stake 1e5");
        (, , ,uint256 stakedBalance,uint256 maxStakeDebt,uint256 portalEnergy,uint256 availableToWithdraw) = portal.getUpdateAccount(address(Alice),0);
        console2.log("user stakedBalance", stakedBalance);
        console2.log("user maxStakeDebt", maxStakeDebt);
        console2.log("user portalEnergy", portalEnergy);
        console2.log("user availableToWithdraw", availableToWithdraw);
        portal.stake(1e5);
        console2.log("user stake 1e5 again");
        (, , ,uint256 stakedBalance1,uint256 maxStakeDebt1,uint256 portalEnergy1,uint256 availableToWithdraw1) = portal.getUpdateAccount(address(Alice),0);
        console2.log("user stakedBalance", stakedBalance1);
        console2.log("user maxStakeDebt", maxStakeDebt1);
        console2.log("user portalEnergy", portalEnergy1);
        console2.log("user availableToWithdraw", availableToWithdraw1);
    }
    // ---------------------------------------------------
    // ---------------------mint,burn---------------------
    // ---------------------------------------------------

    // ---------------------------------------------------
    // ---------------buy and sell energy token-----------
    // ---------------------------------------------------
    
    // revert
    function testrevert_notexitaccount() external {
        help_fundAndActivate();
        vm.expectRevert();
        portal.buyPortalEnergy(1e18, 1e18, block.timestamp);
    }
    function testrevert_buy0() external {
        help_fundAndActivate();
        help_stake();
        vm.startPrank(Alice);
        vm.expectRevert();
        portal.buyPortalEnergy(0, 0, 0);
    }

    // event

    // buy and sell

    // ---------------------------------------------------
    // --------------------compound-----------------------
    // ---------------------------------------------------
    // revert
    // event
    // compound

    // ---------------------------------------------------
    // ---------------------convert-----------------------
    // ---------------------------------------------------

    // revert
    // event
    // convert
    
    // ---------------------------------------------------
    // ---------------------view--------------------------
    // ---------------------------------------------------

}
