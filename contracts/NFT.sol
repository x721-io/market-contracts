// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "./interfaces/IERC721Modified.sol";

contract NFT is IERC721Modified, ERC721 {
    uint256 private _tokenIdCounter;

    constructor() ERC721("NFT1", "NFTSYM1") {}

    function balanceOf(address owner) public view override(ERC721, IERC721Modified) returns (uint) {
        return super.balanceOf(owner);
    }

    function mintNFT(address to) external override returns (uint) {
        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter = _tokenIdCounter + 1;
        _safeMint(to, tokenId + 1);

        return tokenId + 1;
    }

    function mintBatchNFT(address to, uint amount) external returns (uint[] memory) {
        uint[] memory tokenIds = new uint[](amount);
        for (uint i = 0; i < amount; i++) {
            uint256 tokenId = _tokenIdCounter;
            _tokenIdCounter = _tokenIdCounter + 1;
            _safeMint(to, tokenId + 1);
            tokenIds[i] = tokenId + 1;
        }

        return tokenIds;
    }
    
    function safeTransferNFTFrom(address from, address to, uint tokenId) external override {
        super.safeTransferFrom(from, to, tokenId);
    }
}
