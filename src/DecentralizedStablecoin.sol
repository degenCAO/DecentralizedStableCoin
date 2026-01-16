// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable(msg.sender) {
    constructor() ERC20("DecentralizedStablecoin", "DCS") {}

    error DecentralizedStablecoin__MustBeMoreThanZero();
    error DecentralizedStablecoin__AmountExceedsBalance();
    error DecentralizedStablecoin__CantMintToZeroAddress();
    error DecentralizedStablecoin__AmountCantBeZero();

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStablecoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStablecoin__AmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStablecoin__CantMintToZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStablecoin__AmountCantBeZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
