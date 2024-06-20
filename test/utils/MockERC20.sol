//SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from
    "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";


contract MockERC20 is ERC20, ERC20Permit{

	constructor(string memory _name, string memory _symbol)
		ERC20(_name, _symbol) ERC20Permit(_name){
	}

	function mint(address dest, uint256 amount)  public {
		_mint(dest, amount);
	}

}
