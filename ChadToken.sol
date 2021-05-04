// SPDX-License-Identifier: MIT

pragma solidity >=0.5.0 <0.7.0;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

/*
 ██████╗██╗  ██╗██╗  ██╗██████╗
██╔════╝██║  ██║██║  ██║██╔══██╗
██║     ███████║███████║██║  ██║
██║     ██╔══██║╚════██║██║  ██║
╚██████╗██║  ██║     ██║██████╔╝
╚═════╝╚═╝  ╚═╝     ╚═╝╚═════╝
*/

contract ChadToken is Ownable, ERC20 {
  constructor() public ERC20('Chad', 'CHAD') {}

  function mint(address account, uint256 amount) external onlyOwner {
    _mint(account, amount);
  }
}
