// SPDX-License-Identifier: MIT

pragma solidity ^0.8.5;

import "./Ownable.sol";
import "./IERC20.sol";

contract SwapHelper is Ownable {
  event ApprovalSet(address indexed token, address indexed spender, uint256 amount);
  constructor() {}

  function safeApprove(address token, address spender, uint256 amount) external onlyOwner {
        IERC20(token).approve(spender, amount);
        emit ApprovalSet(token, spender, amount);
    }
}