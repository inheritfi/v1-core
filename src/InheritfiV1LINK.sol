// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./InheritfiV1Base.sol";

/**
 * @title INHERITFI V1 LINK
 * @notice Wraps LINK into iLINK with inheritance and recovery mechanics.
 * @author INHERITFI ( https://inheritfi.com / inheritfi.eth )
 */
contract InheritfiV1LINK is InheritfiV1Base {

    using SafeERC20 for IERC20;

    IERC20 public immutable LINK;

    constructor(address _link) ERC20("INHERITFI V1 LINK", "iLINK") Ownable(msg.sender) {
        require(_link != address(0), "Bad LINK addr");
        LINK = IERC20(_link);
        _initBase();
    }

    // ============ Wrap / Unwrap ============

    function wrap(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        LINK.safeTransferFrom(msg.sender, address(this), amount);
        (uint256 tax, uint256 net) = _taxSplit(amount, wrappingTax);
        if (tax > 0) accumulatedTax += tax;
        UserData storage user = userData[msg.sender];
        user.totalReceived    += net;
        _touch();
        if (tax > 0) _mint(address(this), tax);
        _mint(msg.sender, net);
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
        LINK.safeTransfer(msg.sender, net);
        emit Unwrapped(msg.sender, amount, net, tax);
    }

    // ============ Emergency LINK Recovery ============

    function _underlyingAsset() internal view override returns (address) {
        return address(LINK);
    }

    function getRecoverableLINK() public view returns (uint256) {
        uint256 bal = LINK.balanceOf(address(this));
        uint256 sup = totalSupply();
        return bal > sup ? bal - sup : 0;
    }

    function emergencyRecoverLINK(address to, uint256 amount) external onlyOwnerAlive {
        require(to != address(0) && amount > 0, "Bad input");
        require(amount <= getRecoverableLINK(), "Exceeds recoverable");
        LINK.safeTransfer(to, amount);
        emit EmergencyRecovery(address(LINK), to, amount, "LINK-EXCESS");
    }

    function emergencyRecoverERC20(address tokenContract, address to, uint256 amount) external onlyOwnerAlive {
        require(to != address(0) && tokenContract != address(0), "Bad addr");
        require(tokenContract != address(LINK), "Use emergencyRecoverLINK");
        require(amount > 0, "Zero amount");
        if (tokenContract == address(this)) {
            require(amount <= getRecoverableITokens(), "Exceeds recoverable");
            _transfer(address(this), to, amount);
            emit EmergencyRecovery(tokenContract, to, amount, "iLINK-EXCESS");
        } else {
            IERC20 token = IERC20(tokenContract);
            require(token.balanceOf(address(this)) >= amount, "Insufficient balance");
            token.safeTransfer(to, amount);
            emit EmergencyRecovery(tokenContract, to, amount, "ERC20");
        }
    }

    function emergencyRecoverETH(address payable to, uint256 amount) external onlyOwnerAlive {
        require(to != address(0) && amount > 0 && address(this).balance >= amount, "Bad input");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "Transfer failed");
        emit EmergencyRecovery(address(0), to, amount, "ETH");
    }
}
