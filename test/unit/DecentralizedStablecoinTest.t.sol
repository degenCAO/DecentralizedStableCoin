// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStablecoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoinTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    address USER = makeAddr("user");

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine,) = deployer.run();
    }

    function testOnlyOwnerCanMint() public {
        vm.prank(USER);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        dsc.mint(msg.sender, type(uint96).max);
        vm.stopPrank();
    }

    function testOnlyOwnerCanBurn() public {
        vm.prank(address(engine));
        dsc.mint(USER, type(uint96).max);
        vm.stopPrank();
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        dsc.burn(type(uint96).max);
        vm.stopPrank();
    }
}
