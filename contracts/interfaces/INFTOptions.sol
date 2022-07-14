// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

interface INFTOptions {
    function exerciseOption(uint256 id) external payable;

    function getOptionDetails(uint256 id) external view returns (uint256 amount, address token, address paymentCurrency, uint256 strike);
}