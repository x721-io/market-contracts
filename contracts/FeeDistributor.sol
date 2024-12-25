// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./libraries/LibStructsMarketplace.sol";

import "./interfaces/IRoyaltiesRegistry.sol";
import "./interfaces/INFTU2U.sol";

contract FeeDistributor is OwnableUpgradeable {

  address public protocolFeeRecipient;
  address public marketplaceERC721;
  address public marketplaceERC1155;
  IRoyaltiesRegistry public royaltiesRegistry;
  uint public protocolFeePercent;
  // 5000 = 50% <=> 50% seller, 50% buyer
  // 7000 = 70% <=> 70% seller, 30% buyer
  uint public feeRatioSellerBuyer;

  uint public constant MAX_FEE = 500; // 5%

  function initialize(
    address _marketplaceERC721,
    address _marketplaceERC1155,
    address _royaltiesRegistry,
    address _recipient,
    uint _feePercent,
    uint _feeRatioSellerBuyer
  ) public initializer {
    __Ownable_init(msg.sender);
    require(_feePercent <= 500, "U2U: max fee");
    marketplaceERC721 = _marketplaceERC721;
    marketplaceERC1155 = _marketplaceERC1155;
    royaltiesRegistry = IRoyaltiesRegistry(_royaltiesRegistry);
    protocolFeeRecipient = _recipient;
    protocolFeePercent = _feePercent;
    feeRatioSellerBuyer = _feeRatioSellerBuyer;
  }

  function setProtocolFeeRecipient(address _recipient) external onlyOwner {
    protocolFeeRecipient = _recipient;
  }

  function setProtocolFeePercent(uint _percent) external onlyOwner {
    require(_percent <= MAX_FEE, "max_fee");
    protocolFeePercent = _percent;
  }

  function setFeeRatio(uint ratio) external onlyOwner {
    require(ratio <= 10000, "U2U: invalid ratio");
    feeRatioSellerBuyer = ratio;
  }

  function setMarketplaceERC721(address newMarketplace, bool marketplaceType) external onlyOwner {
    require(newMarketplace != address(0), "U2U: zero address");
    if (marketplaceType) {
      marketplaceERC721 = newMarketplace;
    } else {
      marketplaceERC1155 = newMarketplace;
    }
  }

  function setRoyaltiesRegistry(address newRegistry) external onlyOwner {
    require(newRegistry != address(0), "U2U: zero address");
    royaltiesRegistry = IRoyaltiesRegistry(newRegistry);
  }

  function distributeFees(
    address nft,
    address quoteToken,
    uint value,
    uint tokenId,
    uint price
  ) external returns (uint) {
    require(nft != address(0) && price != 0, "U2U: nft = address(0) or price = 0");
    require(marketplaceERC1155 != address(0) && marketplaceERC721 != address(0), "U2U: marketplace = address(0)");

    uint remaining = value;
    if (protocolFeeRecipient != address(0)) {
      uint fee = price * protocolFeePercent / 10000;
      remaining = value - fee;
      ERC20Upgradeable(quoteToken).transfer(protocolFeeRecipient, fee);
    }

    LibStructsMarketplace.RoyaltiesType royaltiesType = royaltiesRegistry.getRoyaltiesType(nft);

    uint sumRoyalties = 0;
    if (royaltiesType == LibStructsMarketplace.RoyaltiesType.Collection) {
      LibStructsMarketplace.Part[] memory royalties = royaltiesRegistry.getRoyalties(nft, tokenId);
      sumRoyalties = _transferRoyalties(quoteToken, price, royalties);
      remaining = remaining - sumRoyalties;
    } else {
      try INFTU2U(nft).getRaribleV2Royalties(tokenId) returns (LibStructsMarketplace.Part[] memory _royalties) {
        sumRoyalties = _transferRoyalties(quoteToken, price, _royalties);
        remaining = remaining - sumRoyalties;
      } catch {}
    }

    if (msg.sender == marketplaceERC721) {
      ERC20Upgradeable(quoteToken).transfer(marketplaceERC721, remaining);
    } else if (msg.sender == marketplaceERC1155) {
      ERC20Upgradeable(quoteToken).transfer(marketplaceERC1155, remaining);
    }

    return remaining;
  }

  function calculateFee(uint price, address nft, uint tokenId) external view returns (uint, uint, uint, uint) {
    uint feeSeller = 0;
    uint feeBuyer = 0;
    uint royaltiesFee = 0;
    uint netReceived = price;

    // Calculate Royalties & netReceived
    if (protocolFeeRecipient != address(0)) {
      feeSeller = (price * protocolFeePercent * feeRatioSellerBuyer) / 100000000;
      feeBuyer = (price * protocolFeePercent * (10000 - feeRatioSellerBuyer)) / 100000000;
      netReceived = price - feeSeller;
    }

    LibStructsMarketplace.RoyaltiesType royaltiesType = royaltiesRegistry.getRoyaltiesType(nft);
    if (royaltiesType == LibStructsMarketplace.RoyaltiesType.Collection) {
      LibStructsMarketplace.Part[] memory royalties = royaltiesRegistry.getRoyalties(nft, tokenId);
      royaltiesFee = _calculateRoyalties(price, royalties);
      netReceived = netReceived - royaltiesFee;
    } else {
      try INFTU2U(nft).getRaribleV2Royalties(tokenId) returns (LibStructsMarketplace.Part[] memory _royalties) {
        royaltiesFee = _calculateRoyalties(price, _royalties);
        netReceived = netReceived - royaltiesFee;
      } catch {}
    }

    return (feeSeller, feeBuyer, royaltiesFee, netReceived);
  }

  function calculateBuyerProtocolFee(uint price) external view returns (uint) {
    uint feeBuyer = 0;

    if (protocolFeeRecipient != address(0)) {
      feeBuyer = (price * protocolFeePercent * (10000 - feeRatioSellerBuyer)) / 100000000;
    }

    return (feeBuyer);
  }

  function _calculateRoyalties(
    uint price,
    LibStructsMarketplace.Part[] memory royalties
  ) private pure returns (uint) {
    uint sumRoyalties = 0;
    if (royalties.length > 0) {
      for (uint i = 0; i < royalties.length; i = i + 1) {
        if (royalties[i].value > 0) {
          uint256 royaltyFee = (price * royalties[i].value) / 10000;
          sumRoyalties = sumRoyalties + royaltyFee;
        }
      }
    }

    return sumRoyalties;
  }

  function _transferRoyalties(
    address quoteToken,
    uint price,
    LibStructsMarketplace.Part[] memory royalties
  ) private returns (uint) {
    // require(royalties.length > 0, "U2U: royalties length = 0");
    uint sumRoyalties = 0;
    if (royalties.length > 0) {
      for (uint i = 0; i < royalties.length; i = i + 1) {
        if (royalties[i].value > 0) {
          uint royaltyFee = price * royalties[i].value / 10000;
          sumRoyalties = sumRoyalties + royaltyFee;
          ERC20Upgradeable(quoteToken).transfer(royalties[i].account, royaltyFee);
        }
      }
    }

    return sumRoyalties;
  }
}