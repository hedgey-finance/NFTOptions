// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.7;

interface SpecialSwap {
  function specialSwap(
    uint256 _id,
    address payable originalOwner,
    address[] memory path,
    uint256 totalPurchase
  ) external;
}