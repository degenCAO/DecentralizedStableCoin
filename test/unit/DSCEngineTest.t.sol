// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStablecoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
    uint256 public constant MINTED_DSC = 500 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier mintedDsc() {
        vm.startPrank(USER);
        engine.mintDsc(MINTED_DSC);
        vm.stopPrank();
        _;
    }

    /////////////////
    ///PRICE TESTS///
    /////////////////

    function testGetUsdValue() public view {
        uint256 amount = 25e18;
        //25*3000 = 75000e18
        uint256 expectedValue = 75000e18;
        uint256 value = engine.getUsdValue(weth, amount);
        assertEq(expectedValue, value);
    }

    function testGetTokenAmountFromUsdValue() public view {
        uint256 usdAmount = 450 ether;
        // $3000/ ETH, 450/3000 = 0.15 ETH
        uint256 expectedWeth = 0.15 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////
    ///CUMSTRUCTOR TESTS///
    ///////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAdresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAdresses.push(ethUsdPriceFeed);
        priceFeedAdresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesArraysMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAdresses, address(dsc));
    }

    ///////////////////
    ///DEPOSIT TESTS///
    ///////////////////

    function testDepositCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock unapprovedToken = new ERC20Mock("UNP", "UNP", USER, STARTING_ERC20_BALANCE);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        engine.depositCollateral(address(unapprovedToken), STARTING_ERC20_BALANCE);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedTotalDscMinet = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, totalCollateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinet);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ////////////////
    ///MINT TESTS///
    ////////////////

    function testCantMintZeroDSC() public depositedCollateral {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testMintReversedIfHealthFactorBroken() public depositedCollateral {
        //Deposited collateral USD value is 10 * 3 000$ = 30 000
        //To broke health factor minted amount should exceed 30 000 / 2 = 15 000$
        uint256 brokenMintAmount = MINTED_DSC * 31; /*(500 * 31 = 15 500 $)*/
        uint256 usdValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor = engine.calculateHealthFactor(brokenMintAmount, usdValue);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(brokenMintAmount);
        vm.stopPrank();
    }

    //////////////////
    ///REDEEM TESTS///
    //////////////////

    function testCantRedeemMoreThanDeposited() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__RedeemingAmountCantExceedDeposited.selector);
        engine.redeemCollateral(address(weth), (AMOUNT_COLLATERAL + AMOUNT_COLLATERAL));
        vm.stopPrank();
    }

    function testCantRedeemWithBrokenHealthFactor() public depositedCollateral {
        uint256 expectedHealthFactor = engine.calculateHealthFactor(MINTED_DSC, 0);
        vm.startPrank(USER);
        engine.mintDsc(MINTED_DSC);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /////////////////////
    ///LIQUIDATE TESTS///
    /////////////////////

    function testCantLiquidateIfHealthFactorIsntBroken() public depositedCollateral mintedDsc {
        uint256 usdValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 startingUserHealthFactor = engine.calculateHealthFactor(MINTED_DSC, usdValue);
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorOK.selector, startingUserHealthFactor));
        engine.liquidate(weth, USER, MINTED_DSC);
        vm.stopPrank();
    }

    //mint dsc for liquidator
    function testCantLiquidateWithoutImprovingUsersHealthFactor() public depositedCollateral mintedDsc {
        int256 ethUsdUpdatedPrice = 90e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        engine.mintDsc(1);
        dsc.approve(address(engine), 1);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        engine.liquidate(weth, USER, 1);
        vm.stopPrank();
    }

    function testCantLiquidateWhileBreakingOwnHealthFactor() public {}

    ////////////////
    ///VIEW TESTS///
    ////////////////

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        uint256 expectedHealthFactor = 1e18;
        assert(expectedHealthFactor == minHealthFactor);
    }
}
