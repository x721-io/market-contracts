// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./libraries/LibStructsMarketplace.sol";

import "./interfaces/IWETH.sol";
import "./interfaces/IFeeDistributor.sol";
import "./interfaces/INFTU2U.sol";

contract ERC721NFTMarketplaceV2 is
  ERC721HolderUpgradeable,
  OwnableUpgradeable,
  ReentrancyGuardUpgradeable
{
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();  
  }

  using EnumerableSet for EnumerableSet.AddressSet;
  using EnumerableSet for EnumerableSet.UintSet;

  IFeeDistributor public feeDistributor;

  struct Ask {
    address seller;
    address quoteToken;
    uint256 price;
  }

  struct BidEntry {
    address quoteToken;
    uint256 price;
    uint feePaid;
  }

  address public WETH;

  // nft => tokenId => ask
  mapping(address => mapping(uint256 => Ask)) public asks;
  // nft => tokenId => bidder=> bid
  mapping(address => mapping(uint256 => mapping(address => BidEntry))) public bids;

  event AskNew(
    address indexed _seller,
    address indexed _nft,
    uint256 _tokenId,
    address _quoteToken,
    uint256 _price
  );
  event AskCancel(
    address indexed _seller,
    address indexed _nft,
    uint256 _tokenId
  );
  event Trade(
    address indexed _seller,
    address indexed buyer,
    address indexed _nft,
    uint256 _tokenId,
    address _quoteToken,
    uint256 _price,
    uint256 _netPrice
  );
  event AcceptBid(
    address indexed _seller,
    address indexed bidder,
    address indexed _nft,
    uint256 _tokenId,
    address _quoteToken,
    uint256 _price,
    uint256 _netPrice
  );
  event Bid(
    address indexed bidder,
    address indexed _nft,
    uint256 _tokenId,
    address _quoteToken,
    uint256 _price
  );
  event CancelBid(
    address indexed bidder,
    address indexed _nft,
    uint256 _tokenId
  );
  event ProtocolFee(uint256 protocolFee);

  modifier notContract() {
    require(!_isContract(msg.sender), "Contract not allowed");
    require(msg.sender == tx.origin, "Proxy contract not allowed");
    _;
  }

  function initialize(address _feeDistributor, address _weth) public initializer {
    __Ownable_init(msg.sender);
    WETH = _weth;
    feeDistributor = IFeeDistributor(_feeDistributor);
  }

  function setFeeDistributor(address newFeeDistributor) external onlyOwner {
    require(newFeeDistributor != address(0), "U2U: zero address");
    feeDistributor = IFeeDistributor(newFeeDistributor);
  }

  /**
   * @notice Create ask order
   * @param _nft: contract address of the NFT
   * @param _tokenId: tokenId of the NFT
   * @param _quoteToken: quote token
   * @param _price: price for listing (in wei)
   */
  function createAsk(
    address _nft,
    uint256 _tokenId,
    address _quoteToken,
    uint256 _price
  ) external nonReentrant notContract {
    // Verify price is not too low/high
    require(_price > 0, "Ask: Price must be greater than zero");

    ERC721Upgradeable(_nft).safeTransferFrom(_msgSender(), address(this), _tokenId);
    asks[_nft][_tokenId] = Ask({
      seller: _msgSender(),
      quoteToken: _quoteToken,
      price: _price
    });
    emit AskNew(_msgSender(), _nft, _tokenId, _quoteToken, _price);
  }

  /**
   * @notice Cancel Ask
   * @param _nft: contract address of the NFT
   * @param _tokenId: tokenId of the NFT
   */
  function cancelAsk(address _nft, uint256 _tokenId) external nonReentrant {
    // Verify the sender has listed it
    require(
      asks[_nft][_tokenId].seller == _msgSender(),
      "Ask: only seller"
    );
    ERC721Upgradeable(_nft).safeTransferFrom(address(this), _msgSender(), _tokenId);
    delete asks[_nft][_tokenId];
    emit AskCancel(_msgSender(), _nft, _tokenId);
  }

  /**
   * @notice Buy
   * @param _nft: contract address of the NFT
   * @param _tokenId: tokenId of the NFT
   * @param _quoteToken: quote token
   * @param _price: price for listing (in wei)
   */
  function buy(
    address _nft,
    uint256 _tokenId,
    address _quoteToken,
    uint256 _price
  ) external notContract nonReentrant {

    require(asks[_nft][_tokenId].seller != address(0), "Token is not sell");
    ERC20Upgradeable(_quoteToken).transferFrom(
      _msgSender(),
      address(this),
      _price
    );
    _buy(_nft, _tokenId, _quoteToken, _price);
  }

  function buyBatch(
    address[] memory nfts,
    uint256[] memory tokenIds,
    address quoteToken
  ) external notContract nonReentrant {

    require(nfts.length == tokenIds.length && nfts.length > 0, "U2U: invalid length");
    uint256 totalPrice;
    
    for (uint256 i = 0; i < nfts.length; i = i + 1) {
      Ask memory ask = asks[nfts[i]][tokenIds[i]];
      totalPrice = totalPrice + ask.price;
      require(quoteToken == ask.quoteToken, "U2U: Incorrect quote token");
    }
    
    uint256 totalFee = feeDistributor.calculateBuyerProtocolFee(totalPrice);
    ERC20Upgradeable(quoteToken).transferFrom(
      _msgSender(),
      address(this),
      totalPrice + totalFee
    );
    
    for (uint256 i = 0; i < nfts.length; i = i + 1) {
      Ask memory ask = asks[nfts[i]][tokenIds[i]];
      (, uint256 feeBuyer,,) = feeDistributor.calculateFee(ask.price, nfts[i], tokenIds[i]);
      _buy(nfts[i], tokenIds[i], quoteToken, ask.price + feeBuyer);
    }
  }

  function _buy(
    address _nft,
    uint256 _tokenId,
    address _quoteToken,
    uint256 _price
  ) private {
    // Checks
    require(address(feeDistributor) != address(0), "U2U: feeDistributor 0");
    Ask memory ask = asks[_nft][_tokenId];
    require(ask.seller != address(0), "Token is not sell");
    require(ask.quoteToken == _quoteToken, "Buy: Incorrect quote token");

    (, uint feeBuyer,, uint netReceived) = feeDistributor.calculateFee(ask.price, _nft, _tokenId);
    require(_price >= ask.price + feeBuyer, "U2U: Not enough");

    if (netReceived % 2 == 1) {
      netReceived = netReceived - 1;
    }

    uint protocolFee = (ask.price * feeDistributor.protocolFeePercent()) / 10000;
    
    // Effects - Update state before interactions
    delete asks[_nft][_tokenId];
    
    // Interactions - External calls last
    ERC20Upgradeable(_quoteToken).transfer(address(feeDistributor), _price);
    uint256 remaining = feeDistributor.distributeFees(_nft, _quoteToken, _price, _tokenId, ask.price);
    ERC20Upgradeable(_quoteToken).transfer(ask.seller, netReceived);
    remaining = remaining - netReceived;
    if (remaining > 0) {
      ERC20Upgradeable(_quoteToken).transfer(feeDistributor.protocolFeeRecipient(), remaining);
    }
    
    ERC721Upgradeable(_nft).safeTransferFrom(address(this), _msgSender(), _tokenId);
    
    emit Trade(
      ask.seller,
      _msgSender(),
      _nft,
      _tokenId,
      _quoteToken,
      _price,
      netReceived
    );
    emit ProtocolFee(protocolFee);
  }

  /**
   * @notice Buy using eth
   * @param _nft: contract address of the NFT
   * @param _tokenId: tokenId of the NFT
   */
  function buyUsingEth(
    address _nft,
    uint256 _tokenId
  ) external payable nonReentrant notContract {
    require(asks[_nft][_tokenId].seller != address(0), "token is not sell");
    IWETH(WETH).deposit{value: msg.value}();
    _buy(_nft, _tokenId, WETH, msg.value);
  }

  function buyUsingEthBatch(address[] memory nfts, uint256[] memory tokenIds) external payable nonReentrant notContract {
    // Checks
    require(nfts.length == tokenIds.length && nfts.length > 0, "U2U: invalid length");
    require(address(feeDistributor) != address(0), "U2U: feeDistributor 0");
    
    uint256 totalPrice;
    Ask[] memory batchAsks = new Ask[](nfts.length);
    uint256[] memory feeBuyers = new uint256[](nfts.length);
    uint256[] memory netReceiveds = new uint256[](nfts.length);
    
    // Load and validate all asks first
    for (uint256 i = 0; i < nfts.length; i++) {
      Ask memory ask = asks[nfts[i]][tokenIds[i]];
      require(ask.seller != address(0), "token is not sell");
      
      totalPrice = totalPrice + ask.price;
      (, feeBuyers[i],, netReceiveds[i]) = feeDistributor.calculateFee(ask.price, nfts[i], tokenIds[i]);
      
      if (netReceiveds[i] % 2 == 1) {
        netReceiveds[i] = netReceiveds[i] - 1;
      }
      
      batchAsks[i] = ask;
    }
    
    uint256 totalFee = feeDistributor.calculateBuyerProtocolFee(totalPrice);
    require(msg.value >= totalPrice + totalFee, "U2U: not enough");
    require(totalPrice + totalFee > 0, "Total price must be greater than 0");
    
    // Effects - Update state before interactions
    for (uint256 i = 0; i < nfts.length; i++) {
      delete asks[nfts[i]][tokenIds[i]];
    }
    
    // Interactions - External calls last
    IWETH(WETH).deposit{value: msg.value}();
    
    for (uint256 i = 0; i < nfts.length; i++) {
      Ask memory ask = batchAsks[i];
      uint256 price = ask.price + feeBuyers[i];
      
      ERC20Upgradeable(WETH).transfer(address(feeDistributor), price);
      uint256 remaining = feeDistributor.distributeFees(nfts[i], WETH, price, tokenIds[i], ask.price);
      ERC20Upgradeable(WETH).transfer(ask.seller, netReceiveds[i]);
      remaining = remaining - netReceiveds[i];
      if (remaining > 0) {
        ERC20Upgradeable(WETH).transfer(feeDistributor.protocolFeeRecipient(), remaining);
      }
      
      ERC721Upgradeable(nfts[i]).safeTransferFrom(address(this), _msgSender(), tokenIds[i]);
      
      uint protocolFee = (ask.price * feeDistributor.protocolFeePercent()) / 10000;
      
      emit Trade(
        ask.seller,
        _msgSender(),
        nfts[i],
        tokenIds[i],
        WETH,
        price,
        netReceiveds[i]
      );
      emit ProtocolFee(protocolFee);
    }
  }

  /**
   * @notice Accept bid
   * @param _nft: contract address of the NFT
   * @param _tokenId: tokenId of the NFT
   * @param _bidder: address of bidder
   * @param _quoteToken: quote token
   */
  //  * @param _price: price for listing (in wei)
  function acceptBid(
    address _nft,
    uint256 _tokenId,
    address _bidder,
    address _quoteToken
  ) external nonReentrant {
    require(address(feeDistributor) != address(0), "U2U: feeDistributor 0");

    BidEntry memory bid = bids[_nft][_tokenId][_bidder];
    (, uint feeBuyer,, uint netReceived) = feeDistributor.calculateFee(bid.price, _nft, _tokenId);
    require(feeBuyer == bid.feePaid, "U2U: fee changed");
    require(bid.quoteToken == _quoteToken, "AcceptBid: invalid quoteToken");

    if (netReceived % 2 == 1) {
      netReceived = netReceived - 1;
    }

    address seller = asks[_nft][_tokenId].seller;
    if (seller == _msgSender()) {
      ERC721Upgradeable(_nft).safeTransferFrom(address(this), _bidder, _tokenId);
    } else {
      seller = _msgSender();
      ERC721Upgradeable(_nft).safeTransferFrom(seller, _bidder, _tokenId);
    }

    uint value = bid.price + bid.feePaid;
    ERC20Upgradeable(_quoteToken).transfer(address(feeDistributor), value);
    uint256 remaining = feeDistributor.distributeFees(_nft, _quoteToken, value, _tokenId, bid.price);
    ERC20Upgradeable(_quoteToken).transfer(seller, netReceived);
    remaining = remaining - netReceived;
    if (remaining > 0) {
      ERC20Upgradeable(_quoteToken).transfer(feeDistributor.protocolFeeRecipient(), remaining);
    }

    uint protocolFee = (bid.price * feeDistributor.protocolFeePercent()) / 10000;

    delete asks[_nft][_tokenId];
    delete bids[_nft][_tokenId][_bidder];
    emit AcceptBid(
      seller,
      _bidder,
      _nft,
      _tokenId,
      _quoteToken,
      bid.price,
      netReceived
    );
    emit ProtocolFee(protocolFee);
  }

  function createBid(
    address _nft,
    uint256 _tokenId,
    address _quoteToken,
    uint256 _price
  ) external notContract nonReentrant {
    (,uint feeBuyer,,) = feeDistributor.calculateFee(_price, _nft, _tokenId);
    ERC20Upgradeable(_quoteToken).transferFrom(
      _msgSender(),
      address(this),
      _price + feeBuyer
    );
    _createBid(_nft, _tokenId, _quoteToken, _price, feeBuyer);
  }

  function _createBid(
    address _nft,
    uint256 _tokenId,
    address _quoteToken,
    uint256 _price,
    uint feeBuyer
  ) private {
    require(_price > 0, "Bid: Price must be granter than zero");
    if (bids[_nft][_tokenId][_msgSender()].price > 0) {
      // cancel old bid
      _cancelBid(_nft, _tokenId);
    }
    bids[_nft][_tokenId][_msgSender()] = BidEntry({
      price: _price,
      quoteToken: _quoteToken,
      feePaid: feeBuyer
    });
    emit Bid(_msgSender(), _nft, _tokenId, _quoteToken, _price);
  }

  function createBidUsingEth(
    address _nft,
    uint256 _tokenId,
    uint _price
  ) external payable notContract nonReentrant {
    (,uint feeBuyer,,) = feeDistributor.calculateFee(_price, _nft, _tokenId);
    require(msg.value >= _price + feeBuyer, "U2U: not enough");
    IWETH(WETH).deposit{value: msg.value}();
    _createBid(_nft, _tokenId, WETH, _price, feeBuyer);
  }

  function cancelBid(address _nft, uint256 _tokenId) external nonReentrant {
    _cancelBid(_nft, _tokenId);
  }

  function _cancelBid(address _nft, uint256 _tokenId) private {
    BidEntry memory bid = bids[_nft][_tokenId][_msgSender()];
    require(bid.price > 0, "Bid: bid not found");
    ERC20Upgradeable(bid.quoteToken).transfer(_msgSender(), bid.price + bid.feePaid);
    delete bids[_nft][_tokenId][_msgSender()];
    emit CancelBid(_msgSender(), _nft, _tokenId);
  }

  function _isContract(address _addr) internal view returns (bool) {
    uint256 size;
    assembly {
      size := extcodesize(_addr)
    }
    return size > 0;
  }
}