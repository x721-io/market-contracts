// SPDX-License-Identifier: MIT

pragma solidity ^0.8.2;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./libraries/LibStructsMarketplace.sol";

import "./interfaces/IWETH.sol";
import "./interfaces/IFeeDistributor.sol";
import "./interfaces/INFTU2U.sol";

contract ERC1155NFTMarketplace is
  ReentrancyGuardUpgradeable,
  ERC1155HolderUpgradeable,
  OwnableUpgradeable
{

  uint256 private _askIds;
  uint256 private _offerIds;
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _askIds = 0;
    _offerIds = 0;
    _disableInitializers();  
  }

  struct Ask {
    address seller;
    address nft;
    uint256 tokenId;
    uint256 quantity;
    address quoteToken;
    uint256 pricePerUnit;
  }

  struct Offer {
    address buyer;
    address nft;
    uint256 tokenId;
    uint256 quantity;
    address quoteToken;
    uint256 pricePerUnit;
    uint feePerUnit;
  }


  mapping(uint256 => Ask) public asks;
  mapping(uint256 => Offer) public offers;

  event AskNew(
    uint256 askId,
    address seller,
    address nft,
    uint256 tokenId,
    uint256 quantity,
    address quoteToken,
    uint256 pricePerUnit
  );

  event AskCancel(uint256 askId);

  event OfferNew(
    uint256 offerId,
    address buyer,
    address nft,
    uint256 tokenId,
    uint256 quantity,
    address quoteToken,
    uint256 pricePerUnit
  );

  event OfferCancel(uint256 offerId);

  event OfferAccept(
    uint256 offerId,
    address seller,
    uint256 quantity,
    uint256 price,
    uint256 netPrice
  );

  event Buy(
    uint256 askId,
    address buyer,
    uint256 quantity,
    uint256 price,
    uint256 netPrice
  );
  event ProtocolFee(uint256 protocolFee);

  modifier notContract() {
    require(!_isContract(msg.sender), "Contract not allowed");
    require(msg.sender == tx.origin, "Proxy contract not allowed");
    _;
  }

  address public WETH;
  IFeeDistributor public feeDistributor;

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
   * @param _quantity: quantity of order
   * @param _quoteToken: quote token
   * @param _pricePerUnit: price per unit (in wei)
   */
  function createAsk(
    address _nft,
    uint256 _tokenId,
    uint256 _quantity,
    address _quoteToken,
    uint256 _pricePerUnit
  ) external nonReentrant notContract {
    require(
      _quantity > 0,
      "ERC1155NFTMarket: _quantity must be greater than zero"
    );
    require(
      _pricePerUnit > 0,
      "ERC1155NFTMarket: _pricePerUnit must be greater than zero"
    );

    _askIds += 1;
    ERC1155Upgradeable(_nft).safeTransferFrom(
      _msgSender(),
      address(this),
      _tokenId,
      _quantity,
      ""
    );
    asks[_askIds] = Ask({
      seller: _msgSender(),
      nft: _nft,
      tokenId: _tokenId,
      quoteToken: _quoteToken,
      pricePerUnit: _pricePerUnit,
      quantity: _quantity
    });

    emit AskNew(
      _askIds,
      _msgSender(),
      _nft,
      _tokenId,
      _quantity,
      _quoteToken,
      _pricePerUnit
    );
  }

  /**
 * @notice Buy nft using ETH
 * @param askId: id of ask
 * @param quantity: quantity to buy
 */
  function buyUsingEth(uint256 askId, uint256 quantity)
    external
    payable
    nonReentrant
    notContract
  {
    Ask storage ask = asks[askId];
    require(
      quantity > 0 && ask.quantity >= quantity,
      "ERC1155NFTMarket: quantity must be greater than zero and less than seller's quantity"
    );
    require(address(feeDistributor) != address(0), "U2U: feeDistributor 0");
    require(
      ask.quoteToken == address(WETH), // Check if the quote token is WETH
      "ERC1155NFTMarket: ask is not in WETH"
    );
    
    uint256 price = ask.pricePerUnit * quantity;
    (, uint feeBuyer,, uint netReceived) = feeDistributor.calculateFee(price, ask.nft, ask.tokenId);
    require(
      msg.value >= price + feeBuyer,
      "ERC1155NFTMarket: insufficient ETH sent"
    );

    ask.quantity = ask.quantity - quantity;
    IWETH(WETH).deposit{value: msg.value}();
    IWETH(WETH).transfer(address(feeDistributor), msg.value);
    uint256 remaining = feeDistributor.distributeFees(ask.nft, address(WETH), msg.value, ask.tokenId, price);
    // Transfer net price to the seller
    IWETH(WETH).transfer(ask.seller, netReceived);

    // Transfer excess WETH to feeRecipient
    remaining = remaining - netReceived;
    if (remaining > 0) {
      IWETH(WETH).transfer(feeDistributor.protocolFeeRecipient(), remaining);
    }

    ERC1155Upgradeable(ask.nft).safeTransferFrom(
      address(this),
      msg.sender,
      ask.tokenId,
      quantity,
      ""
    );

    if (ask.quantity == 0) {
        delete asks[askId];
    }

    uint protocolFee = (price * feeDistributor.protocolFeePercent()) / 10000;

    emit Buy(askId, msg.sender, quantity, price, netReceived);
    emit ProtocolFee(protocolFee);
  }


  /**
  * @notice Create offer using ETH
  * @param _nft: address of NFT contract
  * @param _tokenId: token id of NFT
  * @param _quantity: quantity to offer
  */
  function createOfferUsingEth(
    address _nft,
    uint256 _tokenId,
    uint256 _quantity,
    uint _pricePerUnit
  )
    external
    payable
    nonReentrant
    notContract
  {
    require(
      _quantity > 0 && _pricePerUnit > 0,
      "ERC1155NFTMarket: _quantity and _price must be greater than zero"
    );

    uint256 totalPrice = _pricePerUnit * _quantity;
    (,uint feeBuyer,,) = feeDistributor.calculateFee(totalPrice, _nft, _tokenId);
    uint feePerUnit = feeBuyer / _quantity;
    require(feePerUnit > 0, "U2U: fee = 0");
    require(msg.value >= totalPrice + feeBuyer);

    // Convert ETH to WETH
    IWETH(WETH).deposit{value: msg.value}();

    _offerIds += 1;
    offers[_offerIds] = Offer({
      buyer: msg.sender,
      nft: _nft,
      tokenId: _tokenId,
      quoteToken: address(WETH), // Use WETH as the quote token
      pricePerUnit: _pricePerUnit,
      quantity: _quantity,
      feePerUnit: feePerUnit
    });

    emit OfferNew(
      _offerIds,
      msg.sender,
      _nft,
      _tokenId,
      _quantity,
      address(WETH),
      _pricePerUnit
    );
  }

  /**
   * @notice Cancel Ask
   * @param askId: id of ask
   */
  function cancelAsk(uint256 askId) external nonReentrant {
    require(
      asks[askId].seller == _msgSender(),
      "ERC1155NFTMarket: only seller"
    );
    Ask memory ask = asks[askId];
    ERC1155Upgradeable(ask.nft).safeTransferFrom(
      address(this),
      ask.seller,
      ask.tokenId,
      ask.quantity,
      ""
    );
    delete asks[askId];
    emit AskCancel(askId);
  }

  /**
   * @notice Offer
   * @param _nft: address of nft contract
   * @param _tokenId: token id of nft
   * @param _quantity: quantity to offer
   * @param _quoteToken: quote token
   * @param _pricePerUnit: price per unit
   */
  function createOffer(
    address _nft,
    uint256 _tokenId,
    uint256 _quantity,
    address _quoteToken,
    uint256 _pricePerUnit
  ) external nonReentrant notContract {
    require(
      _quantity > 0 && _pricePerUnit > 0,
      "ERC1155NFTMarket: _quantity and _pricePerUnit must be greater than zero"
    );

    uint256 totalPrice = _pricePerUnit * _quantity;
    (,uint feeBuyer,,) = feeDistributor.calculateFee(totalPrice, _nft, _tokenId);
    uint feePerUnit = feeBuyer / _quantity;
    require(feePerUnit > 0, "U2U: fee = 0");

    _offerIds += 1;
    ERC20Upgradeable(_quoteToken).transferFrom(
      _msgSender(),
      address(this),
      totalPrice + feeBuyer
    );
    offers[_offerIds] = Offer({
      buyer: _msgSender(),
      nft: _nft,
      tokenId: _tokenId,
      quoteToken: _quoteToken,
      pricePerUnit: _pricePerUnit,
      quantity: _quantity,
      feePerUnit: feePerUnit
    });
    emit OfferNew(
      _offerIds,
      _msgSender(),
      _nft,
      _tokenId,
      _quantity,
      _quoteToken,
      _pricePerUnit
    );
  }

  /**
   * @notice Cancel Offer
   * @param offerId: id of the offer
   */
  function cancelOffer(uint256 offerId) external nonReentrant {
    require(
      offers[offerId].buyer == _msgSender(),
      "ERC1155NFTMarket: only offer owner"
    );
    Offer memory offer = offers[offerId];
    ERC20Upgradeable(offer.quoteToken).transfer(
      offer.buyer,
      (offer.feePerUnit * offer.quantity) + (offer.pricePerUnit * offer.quantity)
    );
    delete offers[offerId];
    emit OfferCancel(offerId);
  }

  /**
   * @notice Accept Offer
   * @param offerId: id of the offer
   * @param quantity: quantity to accept
   */
  function acceptOffer(uint256 offerId, uint256 quantity)
    external
    nonReentrant
    notContract
  {
    Offer storage offer = offers[offerId];
    require(
      quantity > 0 && offer.quantity >= quantity,
      "ERC1155NFTMarket: quantity must be greater than zero and less than seller's quantity"
    );
    require(address(feeDistributor) != address(0), "U2U: feeDistributor 0");
    offer.quantity = offer.quantity - quantity;

    uint256 price = offer.pricePerUnit * quantity;
    (, uint feeBuyer ,, uint netReceived) = feeDistributor.calculateFee(price, offer.nft, offer.tokenId);
    require(feeBuyer / quantity == offer.feePerUnit, "U2U: fee changed");

    if (netReceived % 2 == 1) {
      netReceived = netReceived - 1;
    }

    uint value = price + feeBuyer;
    ERC20Upgradeable(offer.quoteToken).transfer(address(feeDistributor), value);
    uint remaining = feeDistributor.distributeFees(offer.nft, offer.quoteToken, value, offer.tokenId, price);
    ERC20Upgradeable(offer.quoteToken).transfer(_msgSender(), netReceived);
    remaining = remaining - netReceived;
    if (remaining > 0) {
      ERC20Upgradeable(offer.quoteToken).transfer(feeDistributor.protocolFeeRecipient(), remaining);
    }
    ERC1155Upgradeable(offer.nft).safeTransferFrom(
      _msgSender(),
      offer.buyer,
      offer.tokenId,
      quantity,
      ""
    );
    if (offer.quantity == 0) {
      delete offers[offerId];
    }
    uint protocolFee = (price * feeDistributor.protocolFeePercent()) / 10000;
    emit OfferAccept(offerId, _msgSender(), quantity, price, netReceived);
    emit ProtocolFee(protocolFee);
  }

  /**
   * @notice Buy nft
   * @param askId: id of ask
   * @param quantity: quantity to buy
   */
  function buy(uint256 askId, uint256 quantity)
    external
    nonReentrant
    notContract
  {
    Ask storage ask = asks[askId];
    require(
      quantity > 0 && ask.quantity >= quantity,
      "ERC1155NFTMarket: quantity must be greater than zero and less than seller's quantity"
    );
    require(address(feeDistributor) != address(0), "U2U: feeDistributor 0");
    uint256 price = ask.pricePerUnit * quantity;
    (, uint feeBuyer,, uint netReceived) = feeDistributor.calculateFee(price, ask.nft, ask.tokenId);

    ask.quantity = ask.quantity - quantity;
    if (netReceived % 2 == 1) {
      netReceived = netReceived - 1;
    }
    
    uint value = price + feeBuyer;
    ERC20Upgradeable(ask.quoteToken).transferFrom(
      _msgSender(),
      address(this),
      value
    );
    ERC20Upgradeable(ask.quoteToken).transfer(address(feeDistributor), value);
    uint256 remaining = feeDistributor.distributeFees(ask.nft, ask.quoteToken, value, ask.tokenId, price);
    ERC20Upgradeable(ask.quoteToken).transfer(ask.seller, netReceived);
    remaining = remaining - netReceived;
    if (remaining > 0) {
      ERC20Upgradeable(ask.quoteToken).transfer(feeDistributor.protocolFeeRecipient(), remaining);
    }
    
    ERC1155Upgradeable(ask.nft).safeTransferFrom(
      address(this),
      _msgSender(),
      ask.tokenId,
      quantity,
      ""
    );
    
    if (ask.quantity == 0) {
      delete asks[askId];
    }

    uint protocolFee = (price * feeDistributor.protocolFeePercent()) / 10000;
    emit Buy(askId, _msgSender(), quantity, price, netReceived);
    emit ProtocolFee(protocolFee);
  }

  function _isContract(address _addr) internal view returns (bool) {
    uint256 size;
    assembly {
      size := extcodesize(_addr)
    }
    return size > 0;
  }
}
