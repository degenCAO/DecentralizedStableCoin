// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.30;

import {DecentralizedStableCoin} from "src/DecentralizedStablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    //errors//
    error DSCEngine__RedeemingAmountCantExceedDeposited();
    error DSCEngine__BurningAmountCantExceedMinted();
    error DSCEngine__AmountMustBeGreaterThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesArraysMustBeSameLength();
    error DSCEngine_NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHalthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK(uint256 healthFactor);

    //state variables//
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_tokenPriceFeed;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //events//

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);
    event DSCBurned(address indexed user, uint256 indexed amount);

    //modifiers//

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__AmountMustBeGreaterThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_tokenPriceFeed[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    //functions//
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesArraysMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_tokenPriceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //external functions//

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountCollateral the amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        if (s_collateralDeposited[msg.sender][tokenCollateralAddress] < amountCollateral) {
            revert DSCEngine__RedeemingAmountCantExceedDeposited();
        }
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        _revertIfHealthFactorBroken(msg.sender);

        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);
    }

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) nonReentrant {
        if (s_DSCMinted[msg.sender] < amount) {
            revert DSCEngine__BurningAmountCantExceedMinted();
        }
        s_DSCMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);

        emit DSCBurned(msg.sender, amount);
    }

    /*
    * @param collateral - The ERC20 address of collateral to liquidate
    * @param user - The user who has broken health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover - The amount of DSC you want to burn to improve users health factor
    * @notice You can partially liquidate a user
    * @notice You will take liquidation bonus for taking users funds
    * @notice This functions working assumes the protocol will be roughly 200% overcollateralized in order for this to work 
    */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK(startingUserHealthFactor);
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalAmountToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
    }

    function getHealthFactor() external view {}

    //private & internal view functions//

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralUsdValue)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralUsdValue = _getAccountCollateralValueInUsd(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralUsdValue) = _getAccountInformation(user);
        uint256 collateralADjustedForThreshold = collateralUsdValue * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
        return (collateralADjustedForThreshold / totalDscMinted);
    }

    function _revertIfHealthFactorBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor > MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHalthFactor(userHealthFactor);
        }
    }

    //public & external view functions//

    function getTokenAmountFromUsd(address collateral, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenPriceFeed[collateral]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((amount * PRECISION) / uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function _getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenPriceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
