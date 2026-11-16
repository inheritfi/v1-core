// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./InheritfiV1Base.sol";

/**
 * @title INHERITFI V1 ETH
 * @notice Wraps native ETH into iETH with inheritance and recovery mechanics.
 * @author INHERITFI ( https://inheritfi.com / inheritfi.eth )
 */
contract InheritfiV1ETH is InheritfiV1Base {

    using SafeERC20 for IERC20;

    constructor() ERC20("INHERITFI V1 ETH", "iETH") Ownable(msg.sender) {
        _initBase();
    }

    // ============ Wrap / Unwrap ============

    function wrap() external payable nonReentrant {
        require(msg.value > 0, "No ETH");
        uint256 amount = msg.value;
        (uint256 tax, uint256 net) = _taxSplit(amount, wrappingTax);
        if (tax > 0) accumulatedTax += tax;
        UserData storage user = userData[msg.sender];
        user.totalReceived    += net;
        _touch();
        _mint(msg.sender, net);
        if (tax > 0) _mint(address(this), tax);
        emit Wrapped(msg.sender, amount, net, tax);
    }

    function unwrap(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        bool isTreasury = _isTreasuryWallet(msg.sender);
        uint256 tax;
        uint256 net = amount;
        if (!isTreasury) {
            (tax, net) = _taxSplit(amount, unwrappingTax);
            accumulatedTax += tax;
            if (tax > 0) _transfer(msg.sender, address(this), tax);
        }
        UserData storage user = userData[msg.sender];
        user.totalSent        += amount;
        _touch();
        _burn(msg.sender, net);
        (bool ok,) = msg.sender.call{value: net}("");
        require(ok, "ETH transfer failed");
        emit Unwrapped(msg.sender, amount, net, tax);
    }

    // ============ Emergency ETH Recovery ============

    function _underlyingAsset() internal pure override returns (address) {
        return address(0);
    }

    function getRecoverableETH() public view returns (uint256) {
        uint256 bal = address(this).balance;
        uint256 sup = totalSupply();
        return bal > sup ? bal - sup : 0;
    }

    function emergencyRecoverETH(address payable to, uint256 amount) external onlyOwnerAlive {
        require(to != address(0) && amount > 0, "Bad input");
        require(amount <= getRecoverableETH(), "Exceeds recoverable");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "Transfer failed");
        emit EmergencyRecovery(address(0), to, amount, "ETH-EXCESS");
    }

    function emergencyRecoverERC20(address tokenContract, address to, uint256 amount) external onlyOwnerAlive {
        require(to != address(0) && tokenContract != address(0) && amount > 0, "Bad input");
        if (tokenContract == address(this)) {
            require(amount <= getRecoverableITokens(), "Exceeds recoverable");
            _transfer(address(this), to, amount);
            emit EmergencyRecovery(tokenContract, to, amount, "iETH-EXCESS");
        } else {
            IERC20 token = IERC20(tokenContract);
            require(token.balanceOf(address(this)) >= amount, "Insufficient balance");
            token.safeTransfer(to, amount);
            emit EmergencyRecovery(tokenContract, to, amount, "ERC20");
        }
    }

    function getRecoveryInfo() external view returns (
        uint256 totalETH, uint256 totalIETHSupply, uint256 recoverableETH, uint256 ethBackingRatio
    ) {
        totalETH        = address(this).balance;
        totalIETHSupply = totalSupply();
        recoverableETH  = getRecoverableETH();
        if (totalIETHSupply > 0) {
            ethBackingRatio = totalETH <= type(uint256).max / BP
                ? (totalETH * BP) / totalIETHSupply
                : type(uint256).max;
        }
    }
}
