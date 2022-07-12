// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

//import './ERC721/ERC721.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import './ERC721/ERC721Enumerable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './interfaces/Decimals.sol';
import './interfaces/SpecialSwap.sol';
import './libraries/TransferHelper.sol';
//import 'hardhat/console.sol';

contract ContributorOptions is ERC721Enumerable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using Counters for Counters.Counter;
  Counters.Counter private _tokenIds;

  /// @dev baseURI is the URI directory where the metadata is stored
  string private baseURI;
  /// @dev internal whitelist of swapper contracts
  mapping(address => bool) private swappers;
  /// @dev admin address
  address private admin;
  /// @dev handles weth in case WETH is being held - this allows us to unwrap and deliver ETH upon redemption of a timelocked NFT with ETH
  address payable public weth;

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
    uint256 indexed id,
    address indexed holder,
    uint256 amount,
    address token,
    uint256 expiry,
    uint256 vestDate,
    uint256 strike,
    address paymentCurrency,
    address indexed creator,
    bool swappable
  );

  /// OptionExercised event
  /// @param id The id of the option that was burned
  event OptionExercised(uint256 indexed id);

  /// OptionBurned event, fired when an option is burned
  /// @param id The id of the option that was burned
  event OptionBurned(uint256 indexed id);

  /// URISet event
  /// @param uri The uri value that was set for the baseURI
  event URISet(string uri);

  constructor(
    string memory _name,
    string memory _symbol,
    address payable _weth,
    address _admin
  ) ERC721(_name, _symbol) {
    weth = _weth;
    admin = _admin;
  }

  receive() external payable {}

  modifier onlyAdmin() {
    require(admin == msg.sender, 'ADMIN');
    _;
  }

  /// @notice Creates an option, pulling in funds to the contract for escrow, and creating the struct in storage, and mints the NFT
  /// @param _holder The address to min the NFT to
  /// @param _amount The number of tokens that will be locked up in this option
  /// @param _token The token to lock up in this option
  /// @param _expiry The date in unix time when this option expires
  /// @param _vestDate The date when this option will be available to be exercised
  /// @param _strike The price at which this option can be exercised
  /// @param _paymentCurrency The currency the purchaser will pay for this option
  /// @param _swappable Sets this option to be swappable
  /// @dev the NFT and Option storage struct are mapped to the same uint counter
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
    TransferHelper.transferTokens(_token, msg.sender, address(this), _amount);
    options[newItemId] = Option(_amount, _token, _expiry, _vestDate, _strike, _paymentCurrency, msg.sender, _swappable);
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

  /// @notice the function to physically exercise the option
  /// @dev only the NFT owner can exercise this
  /// @dev this will burn the NFT and delete the storage option struct
  /// @dev uses the internal exerciseOption method to handle all payment processing
  function exerciseOption(uint256 id) external nonReentrant {
    require(ownerOf(id) == msg.sender, 'OPT02');
    Option memory option = options[id];
    require(canTransfer(id), 'OPT03');
    require(option.amount > 0, 'OPT04');
    emit OptionExercised(id);
    _burn(id);
    delete options[id];
    _exercise(msg.sender, option.creator, option.amount, option.token, option.strike, option.paymentCurrency);
  }

  /// @notice this function processes the physical exercise payments, delivering tokens to the NFT owner, and payment to the creator
  function _exercise(
    address _holder,
    address _creator,
    uint256 _amount,
    address _token,
    uint256 _strike,
    address _paymentCurrency
  ) internal {
    uint256 _totalPurchase = (_strike * _amount) / (10**Decimals(_token).decimals());
    require(IERC20(_paymentCurrency).balanceOf(_holder) >= _totalPurchase, 'OPT05');
    TransferHelper.transferPayment(weth, _paymentCurrency, _holder, payable(_creator), _totalPurchase);
    TransferHelper.withdrawTokens(_token, _holder, _amount);
  }

  /// @notice this is the special exercise function that can be called to an external smart contract to handle flash-swapping tokens
  /// @param id is the NFT and Option id mapped to id
  /// @param swapper is the special whitelisted swapper address - external smart contract that handles the flash swapping
  /// @param path is the path which will go through the AMM for tokens to be swapped, may be direct or across the best priced path
  /// @dev this method will transfer the NFT to the external swapper, and the swapper will call the physical exercise function back to this contract
  function specialExercise(
    uint256 id,
    address swapper,
    address[] memory path
  ) external nonReentrant {
    require(ownerOf(id) == msg.sender, 'OPT02');
    Option memory option = options[id];
    require(canTransfer(id), 'OPT03');
    require(option.amount > 0, 'OPT04');
    require(swappers[swapper], 'OPT09');
    require(path.length > 1, 'OPT10');
    require(option.swappable, 'OPT11');
    _transfer(msg.sender, swapper, id);
    uint256 _totalPurchase = (option.strike * option.amount) / (10**Decimals(option.token).decimals());
    SpecialSwap(swapper).specialSwap(id, msg.sender, path, _totalPurchase);
  }

  /// @notice function that will return expired, or burn un-vested options
  /// and will deliver back the tokens to the creator and delete the struct and option entirely
  function burnOption(uint256 id) external nonReentrant {
    Option memory option = options[id];
    require(option.creator == msg.sender || ownerOf(id) == msg.sender, 'OPT06');
    require(!canTransfer(id), 'OPT07');
    require(option.amount > 0, 'OPT08');
    emit OptionBurned(id);
    _burn(id);
    delete options[id];
    TransferHelper.withdrawTokens(option.token, option.creator, option.amount);
  }

  function whitelistSwapper(address _swapper) external onlyAdmin {
    swappers[_swapper] = true;
  }

  function removeSwapper(address _swapper) external onlyAdmin {
    swappers[_swapper] = false;
  }

  function changeAdmin(address _newAdmin) external onlyAdmin {
    admin = _newAdmin;
  }

  function updateBaseURI(string memory _uri) external onlyAdmin {
    baseURI = _uri;
    emit URISet(_uri);
  }

  /// @notice function to determine if a swapper address is whitelisted or not
  function isSwapperWhitelist(address _swapper) public view returns (bool isWhiteListed) {
    isWhiteListed = swappers[_swapper];
  }

  /// @notice function to determine if an NFT can be transferred
  /// @dev only NFTs that are vested and NOT expired can be transferred
  function canTransfer(uint256 id) public view returns (bool transferable) {
    Option memory option = options[id];
    if (option.vestDate <= block.timestamp && option.expiry >= block.timestamp) {
      transferable = true;
    }
  }

  
  /// @notice override the internal _transfer function such that we require canTransfer == true
  function _transfer(
    address from,
    address to,
    uint256 tokenId
  ) internal override {
    require(ownerOf(tokenId) == from, 'ERC721: transfer from incorrect owner');
    require(to != address(0), 'ERC721: transfer to the zero address');
    require(canTransfer(tokenId), 'OPT03');
    _beforeTokenTransfer(from, to, tokenId);

    // Clear approvals from the previous owner
    _approve(address(0), tokenId);

    _balances[from] -= 1;
    _balances[to] += 1;
    _owners[tokenId] = to;

    emit Transfer(from, to, tokenId);

    _afterTokenTransfer(from, to, tokenId);
  }

  /// @dev internal function used by the standard ER721 function tokenURI to retrieve the baseURI privately held to visualize and get the metadata
  function _baseURI() internal view override returns (string memory) {
    return baseURI;
  }
}
