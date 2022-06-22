// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

interface SpecialSwap {
  function specialSwap(
    uint256 _id,
    address originalOwner,
    address[] memory path,
    uint256 totalPurchase
  ) external;
}