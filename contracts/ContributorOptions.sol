// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.13;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './interfaces/Decimals.sol';
import './interfaces/SpecialSwap.sol';
import './libraries/TransferHelper.sol';
import 'hardhat/console.sol';

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

  constructor(
    address payable _weth,
    string memory uri,
    address _admin
  ) ERC721('HedgeyOptions', 'HDGOPT') {
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

  modifier onlyAdmin() {
    /// What would be your opinion on keeping the same error code format and adding a README.md to the project to describe the error code
    require(admin == msg.sender, 'not admin');
    _;
  }

  function whitelistSwapper(address _swapper) external onlyAdmin {
    swappers[_swapper] = true;
  }

  function changeAdmin(address _newAdmin) external onlyAdmin {
    admin = _newAdmin;
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
    bool swappable;
  }

  mapping(uint256 => Option) public options;

  receive() external payable {}

  /// Creates an option
  /// @param _holder The address to min the NFT to
  /// @param _amount The number of tokens that will be locked up in this option
  /// @param _token The token to lock up in this option
  /// @param _expiry The date in unix time when this option expires
  /// @param _vestDate The date when this option will be available to be exercised
  /// @param _strike The price at which this option can be exercised
  /// @param _paymentCurrency The currency the purchaser will pay for this option
  /// @param _swappable Sets this option to be swappable
  function createOption(
    address _holder,
    uint256 _amount,
    address _token,
    uint256 _expiry,
    uint256 _vestDate,
    uint256 _strike,
    address _paymentCurrency,
    bool _swappable
  ) external nonReentrant {
    _tokenIds.increment();
    uint256 newItemId = _tokenIds.current();
    require(_amount > 0 && _token != address(0) && _expiry > block.timestamp, 'OPT01');
    /// @dev pulls funds from the msg.sender into this contract for escrow to be locked until exercised
    TransferHelper.transferTokens(_token, msg.sender, address(this), _amount);
    /// @dev generates the new option struct in storage mapped to the NFT Id
    options[newItemId] = Option(_amount, _token, _expiry, _vestDate, _strike, _paymentCurrency, msg.sender, _swappable);
    /// @dev this safely mints an NFT to the _holder address at the current counter index newItemID.
    /// @dev _safeMint ensures that the receiver address can receive and handle ERC721s - which is either a normal wallet, or a smart contract that has implemented ERC721 receiver
    _safeMint(_holder, newItemId);
    emit OptionCreated(
      newItemId,
      _holder,
      _amount,
      _token,
      _expiry,
      _vestDate,
      _strike,
      _paymentCurrency,
      msg.sender,
      _swappable
    );
  }

  function exerciseOption(uint256 id) external nonReentrant {
    /// @dev ensure that only the owner of the NFT can call this function
    require(ownerOf(id) == msg.sender, 'OPT02');
    /// @dev pull the option data from storage and keep in memory to check requirements and exercise
    Option memory option = options[id];
    require(option.vestDate <= block.timestamp && option.expiry >= block.timestamp, 'OPT03');
    emit OptionExercised(id);
    /// @dev burn the NFT
    _burn(id);
    /// @dev delete the options struct so that the owner cannot call this function again
    delete options[id];
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
    uint256 _totalPurchase = (_strike * _amount) / (10**Decimals(_token).decimals());
    require(IERC20(_paymentCurrency).balanceOf(_holder) >= _totalPurchase, 'OPT05');
    /// @dev transfer the total purchase from the holder to the creator
    TransferHelper.transferPayment(weth, _paymentCurrency, _holder, payable(_creator), _totalPurchase);
    /// @dev transfer the tokens in this contract to the holder
    TransferHelper.withdrawTokens(_token, _holder, _amount);
  }

  function specialExercise(
    uint256 _id,
    address swapper,
    address[] memory path
  ) external nonReentrant {
    /// @dev ensure that only the owner of the NFT can call this function
    require(ownerOf(_id) == msg.sender, 'OPT02');
    /// @dev pull the option data from storage and keep in memory to check requirements and exercise
    Option memory option = options[_id];
    require(option.vestDate <= block.timestamp && option.expiry >= block.timestamp, 'OPT03');
    require(option.amount > 0, 'OPT04');
    require(swappers[swapper], 'OPT09');
    require(path.length > 1, 'OPT10');
    require(option.swappable, 'OPT11');
    _transfer(msg.sender, swapper, _id);
    /// @dev call the swap function which will flash loan borrow tokens from an AMM and exercise the option and payout both parties
    uint256 _totalPurchase = (option.strike * option.amount) / (10**Decimals(option.token).decimals());
    SpecialSwap(swapper).specialSwap(_id, msg.sender, path, _totalPurchase);
  }

  /// @notice function that will return expired, or burn un-vested options
  /// and will deliver back the tokens to the creator and delete the struct and option entirely
  function burnOption(uint256 _id) external nonReentrant {
    Option memory option = options[_id];
    /// @dev only the creator or owner can burn it (not sure why the owner would burn it, but no reason they couldn't)
    require(option.creator == msg.sender || ownerOf(_id) == msg.sender, 'OPT06');
    /// @dev require that the expiration date is in the past or that the vestdate is in the future
    require(option.expiry < block.timestamp || option.vestDate > block.timestamp, 'OPT07');
    /// @dev require amount to be greater than 0
    require(option.amount > 0, 'OPT08');
    emit OptionBurned(_id);
    /// @dev burn the NFT
    _burn(_id);
    /// @dev delete the options struct so that the owner cannot call this function again
    delete options[_id];
    /// @dev retun tokens back to creator
    TransferHelper.withdrawTokens(option.token, option.creator, option.amount);
  }

  /// OptionCreated event
  /// @param id The id of the option
  /// @param holder The address to min the NFT to
  /// @param amount The number of tokens that will be locked up in this option
  /// @param token The token to lock up in this option
  /// @param expiry The date in unix time when this option expires
  /// @param vestDate The date when this option will be available to be exercised
  /// @param strike The price at which this option can be exercised
  /// @param paymentCurrency The currency the purchaser will pay for this option
  /// @param creator The address that created the option
  /// @param swappable Sets this option to be swappable
  event OptionCreated(
    uint256 id,
    address holder,
    uint256 amount,
    address token,
    uint256 expiry,
    uint256 vestDate,
    uint256 strike,
    address paymentCurrency,
    address creator,
    bool swappable
  );

  /// OptionExercised event
  /// @param id The id of the option that was burned
  event OptionExercised(uint256 id);

  /// OptionBurned event, fired when an option is burned
  /// @param id The id of the option that was burned
  event OptionBurned(uint256 id);
  
  /// URISet event
  /// @param uri The uri value that was set for the baseURI
  event URISet(string uri);
}
