// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStablecoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;

    address[] public usersWithCollateral;
    uint256 timesMintCalled;
    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }

    function mintDsc(uint256 amountToMint, uint256 addressSeed) public {
        if (usersWithCollateral.length == 0) return;
        address sender = usersWithCollateral[(addressSeed % usersWithCollateral.length)];
        (uint256 totalDscMinted, uint256 collateralUsdValue) = engine.getAccountInformation(sender);
        int256 maxDscToMint = int256(collateralUsdValue / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) return;
        else amountToMint = bound(amountToMint, 0, uint256(maxDscToMint));
        if (amountToMint == 0) return;
        vm.startPrank(sender);
        engine.mintDsc(amountToMint);
        vm.stopPrank();
        timesMintCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getAddressFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        // mint and approve!
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateral.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getAddressFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) return;
        vm.startPrank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function liquidateUser(uint256 collateralSeed, address userForLiquidation, uint256 debtToCover) public {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        uint256 userHealthFactor = engine.getHealthFactor(userForLiquidation);
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getAddressFromSeed(collateralSeed);
        engine.liquidate(address(collateral), userForLiquidation, debtToCover);
    }

    //helper function

    function _getAddressFromSeed(uint256 collateralSeed) internal view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) return weth;
        else return wbtc;
    }

    function howManyTimesMintCalled() public view returns (uint256) {
        return timesMintCalled;
    }
}
