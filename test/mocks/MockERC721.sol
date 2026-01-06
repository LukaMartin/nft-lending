// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

contract MockERC721 {
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _ownerOf;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    function setBalance(address account, uint256 balance) external {
        _balances[account] = balance;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function setTokenId(address account, uint256 tokenId) external {
        if (_ownerOf[tokenId] == address(0)) {
            _ownerOf[tokenId] = account;
            _balances[account] += 1;
        }
    }

    function ownerOf(uint256 tokenId) external view returns (address owner) {
        owner = _ownerOf[tokenId];
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(_ownerOf[tokenId] == from, "Not owner");
        require(from == msg.sender || _operatorApprovals[from][msg.sender], "Not approved");

        _ownerOf[tokenId] = to;
        _balances[from] -= 1;
        _balances[to] += 1;
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }
}
