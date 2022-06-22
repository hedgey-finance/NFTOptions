// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.13;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

interface Decimals {
  function decimals() external view returns (uint256);
}

interface SpecialSwap {
    function specialSwap(uint256 _id, address originalOwner, address[] memory path, uint256 totalPurchase) external;
}

contract ContributorOptions is ERC721Enumerable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using Counters for Counters.Counter;
  Counters.Counter private _tokenIds;

  /// @dev handles weth in case WETH is being held - this allows us to unwrap and deliver ETH upon redemption of a timelocked NFT with ETH
  address payable public weth;
  /// @dev baseURI is the URI directory where the metadata is stored
  string private baseURI;
  /// @dev this is a counter used so that the baseURI can only be set once after deployment
  uint8 private uriSet = 0;
  /// @dev internal whitelist of swapper contracts
  mapping(address => bool) private swappers;
  /// @dev admin address
  address private admin;

  constructor(address payable _weth, string memory uri, address _admin) ERC721('HedgeyOptions', 'HDGOPT') {
    weth = _weth;
    baseURI = uri;
    admin = _admin;
  }

  /// @dev internal function used by the standard ER721 function tokenURI to retrieve the baseURI privately held to visualize and get the metadata
  function _baseURI() internal view override returns (string memory) {
    return baseURI;
  }

  /// @notice function to set the base URI after the contract has been launched, only once - this is done by the admin
  /// @notice there is no actual on-chain functions that require this URI to be anything beyond a blank string ("")
  /// @param _uri is the
  function updateBaseURI(string memory _uri) external {
    /// @dev this function can only be called once - when the public variable uriSet is set to 0
    require(uriSet == 0, 'NFT02');
    /// @dev update the baseURI with the new _uri
    baseURI = _uri;
    /// @dev set the public variable uriSet to 1 so that this function cannot be called anymore
    /// @dev cheaper to use uint8 than bool for this admin safety feature
    uriSet = 1;
    /// @dev emit event of the update uri
    emit URISet(_uri);
  }

  function whitelistSwapper(address _swapper) external {
    require(msg.sender == admin, "not the admin");
    swappers[_swapper] = true;
  }

  function isSwapperWhitelist(address _swapper) external view returns (bool isWhiteListed) {
    isWhiteListed = swappers[_swapper];
  }

  struct Option {
    uint256 amount;
    address token;
    uint256 expiry;
    uint256 vestDate;
    uint256 strike;
    address paymentCurrency;
    address creator;
  }

  mapping(uint256 => Option) public options;

  receive() external payable {}

  function createOption(
    address _holder,
    uint256 _amount,
    address _token,
    uint256 _expiry,
    uint256 _vestDate,
    uint256 _strike,
    address _paymentCurrency
  ) external nonReentrant {
    /// @dev increment our counter by 1
    _tokenIds.increment();
    /// @dev set our newItemID do the current counter uint
    uint256 newItemId = _tokenIds.current();
    require(_amount > 0 && _token != address(0) && _expiry > block.timestamp, 'OPT01');
    /// @dev pulls funds from the msg.sender into this contract for escrow to be locked until exercised
    SafeERC20.safeTransferFrom(IERC20(_token), msg.sender, address(this), _amount);
    /// @dev generates the new option struct in storage mapped to the NFT Id
    options[newItemId] = Option(_amount, _token, _expiry, _vestDate, _strike, _paymentCurrency, msg.sender);
    /// @dev this safely mints an NFT to the _holder address at the current counter index newItemID.
    /// @dev _safeMint ensures that the receiver address can receive and handle ERC721s - which is either a normal wallet, or a smart contract that has implemented ERC721 receiver
    _safeMint(_holder, newItemId);
    emit OptionCreated(newItemId, _holder, _amount, _token, _expiry, _vestDate, _strike, _paymentCurrency, msg.sender);
  }

  function exerciseOption(uint256 _id) external nonReentrant {
    /// @dev ensure that only the owner of the NFT can call this function
    require(ownerOf(_id) == msg.sender, 'OPT02');
    /// @dev pull the option data from storage and keep in memory to check requirements and exercise
    Option memory option = options[_id];
    require(option.vestDate <= block.timestamp && option.expiry >= block.timestamp, 'OPT03');
    require(option.amount > 0, 'OPT04');
    emit OptionExercised(_id);
    /// @dev burn the NFT
    _burn(_id);
    /// @dev delete the options struct so that the owner cannot call this function again
    delete options[_id];
    /// @dev now we actually perform the exercise functions
    _exercise(msg.sender, option.creator, option.amount, option.token, option.strike, option.paymentCurrency);
  }

  /// @notice this function will check the balances of the holder, transfer the proper amount to the
  function _exercise(
    address _holder,
    address _creator,
    uint256 _amount,
    address _token,
    uint256 _strike,
    address _paymentCurrency
  ) internal {
    /// @dev calculate the total purchase amount, which is the strike times the amount
    /// @dev adjusted for the token decimals: because strike is in token decimals, amount in paymentCurrency decimals, and we want to send paymentCurrency
    /// @dev so we divide by tokenDecimals to be left with paymentCurrency decimals up top
    uint256 _totalPurchase = (_strike * _amount) / (10 ** Decimals(_token).decimals());
    require(IERC20(_paymentCurrency).balanceOf(_holder) >= _totalPurchase, 'OPT05');
    /// @dev transfer the total purchase from the holder to the creator
    SafeERC20.safeTransferFrom(IERC20(_paymentCurrency), _holder, _creator, _totalPurchase);
    /// @dev transfer the tokens in this contract to the holder
    SafeERC20.safeTransfer(IERC20(_token), _holder, _amount);
  }

  function returnExpiredOption(uint256 _id) external nonReentrant {
    Option memory option = options[_id];
    /// @dev only the creator can burn this NFT
    require(option.creator == msg.sender, 'OPT06');
    /// @dev require that the expiration date is in the past
    require(option.expiry < block.timestamp, 'OPT07');
    /// @dev require amount to be greater than 0
    require(option.amount > 0, 'OPT08');
    emit OptionReturned(_id);
    /// @dev burn the NFT
    _burn(_id);
    /// @dev delete the options struct so that the owner cannot call this function again
    delete options[_id];
    /// @dev retun tokens back to creator
    SafeERC20.safeTransfer(IERC20(option.token), option.creator, option.amount);
  }

  function specialExercise(uint256 _id, address swapper, address[] memory path) external nonReentrant {
    /// @dev ensure that only the owner of the NFT can call this function
    require(ownerOf(_id) == msg.sender, 'OPT02');
    /// @dev pull the option data from storage and keep in memory to check requirements and exercise
    Option memory option = options[_id];
    require(option.vestDate <= block.timestamp && option.expiry >= block.timestamp, 'OPT03');
    require(option.amount > 0, 'OPT04');
    require(swappers[swapper], 'OPT09');
    require(path.length > 1, 'OPT10');
    _transfer(msg.sender, swapper, _id);
    /// @dev call the swap function which will flash loan borrow tokens from an AMM and exercise the option and payout both parties
    uint256 _totalPurchase = (option.strike * option.amount) / (10 ** Decimals(option.token).decimals());
    SpecialSwap(swapper).specialSwap(_id, msg.sender, path, _totalPurchase);
  }

  /// @notice events
  event OptionCreated(
    uint256 _id,
    address _holder,
    uint256 _amount,
    address _token,
    uint256 _expiry,
    uint256 _vestDate,
    uint256 _strike,
    address _paymentCurrency,
    address _creator
  );
  event OptionExercised(uint256 _id);
  event OptionReturned(uint256 _id);
  event URISet(string _uri);
}
