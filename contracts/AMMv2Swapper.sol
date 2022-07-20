// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import './interfaces/IWETH.sol';
import './interfaces/INFTOptions.sol';
import './interfaces/IUniswapV2Pair.sol';
import './interfaces/IUniswapV2Factory.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';

contract AMMv2Swapper is ReentrancyGuard {
  using SafeERC20 for IERC20;

  address payable public nftOptions;
  address public factory;
  address payable public weth;
  uint8 public ammFee;
  uint16 private constant TENTHOUSAND = 10000;

  constructor(
    address payable _nftOptions,
    address _factory,
    uint8 _ammFee,
    address payable _weth
  ) {
    nftOptions = _nftOptions;
    factory = _factory;
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
    require(msg.sender == nftOptions, 'SWAP01');
    bytes memory data;
    (,address token, address paymentCurrency,) = INFTOptions(nftOptions).getOptionDetails(
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
    // the flashswap will borrow the paymentCurrency totalPurhase - then exercise the call getting the tokens back, then repay the pools with the token proceeds
    flashSwap(path[path.length - 2], path[path.length - 1], totalPurchase, data);
    // now we process the profits post swap and send to the original option owner
    if (paymentCurrency == weth) {
      if (path.length == 2) {
        // this will actually swap the entire balance of the tokens
        swapOut(path[0], path[1], IERC20(path[0]).balanceOf(address(this)), address(this));
      } else {
        multiSwap(path, 0, IERC20(path[0]).balanceOf(address(this)), address(this)); //swap asset to WETH
      }
      //transfer out WETH as ETH to original owner
      uint256 wethBalance = IERC20(weth).balanceOf(address(this));
      IWETH(weth).withdraw(wethBalance);
      (bool success, ) = originalOwner.call{value: wethBalance}('');
      require(success, 'THL04');
    } else {
      if (path.length == 2) {
        swapOut(path[0], path[1], IERC20(path[0]).balanceOf(address(this)), originalOwner);
      } else {
        multiSwap(path, 0, IERC20(path[0]).balanceOf(address(this)), originalOwner);
      }
    }
  }

  /// @dev this function gets called when we flash loan tokens from uniswap - its a callback from the uniswap pair pool
  /// @dev when this is called we exercise the call option, and then swap back the tokens via the path and payback the uniswap pair pool
  function uniswapV2Call(
    address sender,
    uint256 amount0,
    uint256 amount1,
    bytes memory data
  ) external {
    address token0 = IUniswapV2Pair(msg.sender).token0();
    address token1 = IUniswapV2Pair(msg.sender).token1();
    (uint256 reserveA, uint256 reserveB) = getReserves(token0, token1);
    assert(msg.sender == IUniswapV2Factory(factory).getPair(token0, token1));
    (uint256 optionId, address token, address paymentCurrency, address[] memory path, bool directSwap) = abi.decode(
      data,
      (uint256, address, address, address[], bool)
    );
    uint256 amountDue = amount0 == 0
      ? getAmountIn(amount1, reserveA, reserveB)
      : getAmountIn(amount0, reserveB, reserveA);
    uint256 totalPurchase = amount0 == 0 ? amount1 : amount0;
    /// we've already received the payment currency - exercise now to receive back the token
    exercise(optionId, totalPurchase, paymentCurrency);
    if (directSwap) {
      SafeERC20.safeTransfer(IERC20(token), msg.sender, amountDue);
    } else {
      multiSwap(path, amountDue, 0, msg.sender);
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
      INFTOptions(nftOptions).exerciseOption{value: totalPurchase}(optionId);
    } else {
      SafeERC20.safeIncreaseAllowance(IERC20(paymentCurrency), nftOptions, totalPurchase);
      INFTOptions(nftOptions).exerciseOption(optionId);
    }
  }

  function getAmountOut(
    uint256 amountIn,
    uint256 reserveIn,
    uint256 reserveOut
  ) public view returns (uint256 amountOut) {
    require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
    require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
    uint256 amountInWithFee = amountIn * (TENTHOUSAND - ammFee);
    uint256 numerator = amountInWithFee * reserveOut;
    uint256 denominator = reserveIn * TENTHOUSAND + amountInWithFee;
    amountOut = numerator / denominator;
  }

  // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
  function getAmountIn(
    uint256 amountOut,
    uint256 reserveIn,
    uint256 reserveOut
  ) public view returns (uint256 amountIn) {
    require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
    require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
    uint256 numerator = reserveIn * amountOut * TENTHOUSAND;
    uint256 denominator = (reserveOut - amountOut) * (TENTHOUSAND - ammFee);
    amountIn = (numerator / denominator) + 1;
  }

  // performs chained getAmountOut calculations on any number of pairs
  function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
    require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
    amounts = new uint256[](path.length);
    amounts[0] = amountIn;
    for (uint256 i; i < path.length - 1; i++) {
      (uint256 reserveIn, uint256 reserveOut) = getReserves(path[i], path[i + 1]);
      amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
    }
  }

  // performs chained getAmountIn calculations on any number of pairs
  function getAmountsIn(uint256 amountOut, address[] memory path) public view returns (uint256[] memory amounts) {
    require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
    amounts = new uint256[](path.length);
    amounts[amounts.length - 1] = amountOut;
    for (uint256 i = path.length - 1; i > 0; i--) {
      (uint256 reserveIn, uint256 reserveOut) = getReserves(path[i - 1], path[i]);
      amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
    }
  }

  // fetches and sorts the reserves for a pair
  function getReserves(address tokenA, address tokenB) public view returns (uint256 reserveA, uint256 reserveB) {
    (address token0, ) = sortTokens(tokenA, tokenB);
    address pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
    (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair).getReserves();
    (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
  }

  function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
    require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
    (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
  }

  //function to swap from this contract to uniswap pool
  function swap(
    bool send,
    address tokenIn,
    address tokenOut,
    uint256 _in,
    uint256 out,
    address to
  ) internal {
    address pair = IUniswapV2Factory(factory).getPair(tokenIn, tokenOut);
    if (send) SafeERC20.safeTransfer(IERC20(tokenIn), pair, _in); //sends the asset amount in to the swap
    address token0 = IUniswapV2Pair(pair).token0();
    if (tokenIn == token0) {
      IUniswapV2Pair(pair).swap(0, out, to, new bytes(0));
    } else {
      IUniswapV2Pair(pair).swap(out, 0, to, new bytes(0));
    }
  }

  //function to swap from this contract to uniswap pool
  function swapOut(
    address tokenIn,
    address tokenOut,
    uint256 _in,
    address to
  ) internal {
    address pair = IUniswapV2Factory(factory).getPair(tokenIn, tokenOut);
    (uint256 reserveIn, uint256 reserveOut) = getReserves(tokenIn, tokenOut);
    uint256 out = getAmountOut(_in, reserveIn, reserveOut);
    SafeERC20.safeTransfer(IERC20(tokenIn), pair, _in); //sends the asset amount in to the swap
    address token0 = IUniswapV2Pair(pair).token0();
    if (tokenIn == token0) {
      IUniswapV2Pair(pair).swap(0, out, to, new bytes(0));
    } else {
      IUniswapV2Pair(pair).swap(out, 0, to, new bytes(0));
    }
  }

  function multiSwap(
    address[] memory path,
    uint256 amountOut,
    uint256 amountIn,
    address to
  ) internal {
    require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
    require((amountOut > 0 && amountIn == 0) || (amountIn > 0 && amountOut == 0), 'one of the amounts must be 0');
    uint256[] memory amounts = (amountOut > 0) ? getAmountsIn(amountOut, path) : getAmountsOut(amountIn, path);
    for (uint256 i; i < path.length - 1; i++) {
      address _to = (i < path.length - 2) ? IUniswapV2Factory(factory).getPair(path[i + 1], path[i + 2]) : to;
      swap((i == 0), path[i], path[i + 1], amounts[i], amounts[i + 1], _to);
    }
  }

  function flashSwap(
    address borrowedToken,
    address tokenDue,
    uint256 out,
    bytes memory data
  ) internal {
    address pair = IUniswapV2Factory(factory).getPair(borrowedToken, tokenDue);
    address token0 = IUniswapV2Pair(pair).token0();
    if (borrowedToken == token0) {
      IUniswapV2Pair(pair).swap(0, out, address(this), data);
    } else {
      IUniswapV2Pair(pair).swap(out, 0, address(this), data);
    }
  }
}
