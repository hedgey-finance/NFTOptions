// THIS IS A WORK IN PROGRESS, IT IS NOT A COMPLETED FILE AND SHOULD NOT BE USED!!!!!!!!!

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import './interfaces/IWETH.sol';
import './interfaces/INFTOptions.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import './interfaces/UniswapV3/IUniswapV3Pool.sol';
import './interfaces/UniswapV3/IUniswapV3Factory.sol';


contract AMMv3Swapper is ReentrancyGuard {
  using SafeERC20 for IERC20;

  INFTOptions NFT;
  IUniswapV3Factory Factory;
  address payable public weth;
  uint8 public ammFee;
  uint16 private constant TENTHOUSAND = 10000;

  constructor(
    address payable _nftOptions,
    address _factory,
    uint8 _ammFee,
    address payable _weth
  ) {
    NFT = INFTOptions(_nftOptions);
    Factory = IUniswapV3Factory(_factory);
    weth = _weth;
    ammFee = _ammFee;
  }

  receive() external payable {}

  function specialSwap(
    uint256 optionId,
    address payable originalOwner,
    address[] memory path,
    uint256 totalPurchase
  ) external nonReentrant {
    // only our options contract can call this function
    require(msg.sender == address(NFT), 'SWAP01');
    bytes memory data;
    (,address token, address paymentCurrency,) = NFT.getOptionDetails(
      optionId
    );
    if (path.length == 2) {
      data = abi.encode(optionId, token, paymentCurrency, path, true);
    } else {
      address[] memory _path = new address[](path.length - 1);
      for (uint8 i; i < path.length - 1; i++) {
        _path[i] = path[i];
      }
      data = abi.encode(optionId, token, paymentCurrency, path, false);
    }
    
  }


  /// @notice this is the callback function uniswapv3 sends when processing a flashswap transaction
  function uniswapV3FlashCallback(
    uint256 fee0,
    uint256 fee1,
    bytes calldata data
  ) external {

  }

  function flashLoan(address tokenToBorrow, address tokenToRepay, uint256 exercisePrice, bytes calldata data) internal {
    address pool = Factory.getPool(tokenToBorrow, tokenToRepay, ammFee);
    address token0 = IUniswapV3Pool(pool).token0();
    if (token0 == tokenToBorrow) {
        IUniswapV3Pool(pool).flash(address(this), exercisePrice, 0, data);
    } else {
        IUniswapV3Pool(pool).flash(address(this), 0, exercisePrice, data);
    }
    
  }

  /// @notice function to exercise the option
  /// @dev if the payment currency is weth (ie eth), then we have to withdraw weth and transfer the eth
  /// @dev otherwise we increase the allowance and exercise the option which pulls the funds from this contract
  /// @dev this function will result in this contract receiving the tokens underlying from the options contract
  /// @param optionId is the id of the NFT / option
  /// @param totalPurchase is the strike * the token amount, denominated in the payment currency
  /// @param paymentCurrency is the currency in which we are paying to exercise the option
  function exercise(
    uint256 optionId,
    uint256 totalPurchase,
    address paymentCurrency
  ) internal {
    if (paymentCurrency == weth) {
      IWETH(weth).withdraw(totalPurchase);
      NFT.exerciseOption{value: totalPurchase}(optionId);
    } else {
      SafeERC20.safeIncreaseAllowance(IERC20(paymentCurrency), address(NFT), totalPurchase);
      NFT.exerciseOption(optionId);
    }
  }

}
