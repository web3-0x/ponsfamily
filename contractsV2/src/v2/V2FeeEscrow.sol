// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IV2FeeEscrow} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title V2FeeEscrow
 * @notice Holds every v2 recipient's claimable balance in one place, so
 * protocol and creators claim revenue from across all of their pools in a
 * single transaction instead of collecting per position. Revenue arrives in
 * whichever asset the launch trades against: native ETH for a native launch,
 * and the launch's ERC-20 quote asset otherwise. Both the bonding curve and
 * the post-graduation V2MemeHook credit the same way, so a recipient's
 * balance is denominated identically before and after graduation.
 */
contract V2FeeEscrow is ReentrancyGuard, IV2FeeEscrow {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NoBalance();
    error TransferFailed();
    error InsufficientBalance(uint256 requested, uint256 available);

    event Credited(address indexed recipient, address indexed depositor, uint256 amount);
    event CreditedToken(address indexed recipient, address indexed token, address indexed depositor, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);
    event ClaimedToken(address indexed recipient, address indexed token, uint256 amount);

    mapping(address recipient => uint256 amount) private _balances;
    mapping(address recipient => mapping(address token => uint256 amount)) private _tokenBalances;

    /**
     * @notice Credits `msg.value` to `recipient`'s claimable native ETH balance.
     * @dev Permissionless by design: the caller can only ever add value they
     * already attached to the call, so there is no privilege to gate.
     */
    function credit(address recipient) external payable {
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) return;
        _balances[recipient] += msg.value;
        emit Credited(recipient, msg.sender, msg.value);
    }

    /**
     * @notice Pulls `amount` of `token` from the caller and credits it to `recipient`.
     * @dev Permissionless by design: the caller can only credit tokens they
     * already hold and approve, so there is no privilege to gate. Credits
     * the actual balance delta rather than the nominal `amount`, so a
     * fee-on-transfer or deflationary pairToken can never make this
     * contract record more credited liability than it actually holds,
     * which would otherwise starve whichever recipient claims that token
     * last.
     */
    function creditToken(address recipient, address token, uint256 amount) external nonReentrant {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received == 0) return;
        _tokenBalances[recipient][token] += received;
        emit CreditedToken(recipient, token, msg.sender, received);
    }

    /**
     * @notice Pays out the caller's entire claimable native ETH balance.
     */
    function claim() external nonReentrant returns (uint256 amount) {
        amount = _claim(_balances[msg.sender]);
    }

    /**
     * @notice Pays out `amount` of the caller's claimable native ETH balance.
     */
    function claim(uint256 amount) external nonReentrant returns (uint256) {
        return _claim(amount);
    }

    /**
     * @notice Pays out the caller's entire claimable balance of `token`.
     */
    function claimToken(address token) external nonReentrant returns (uint256 amount) {
        amount = _claimToken(token, _tokenBalances[msg.sender][token]);
    }

    /**
     * @notice Pays out `amount` of the caller's claimable balance of `token`.
     * @dev A recipient's balance aggregates credits from every launch, curve,
     * hook and buyback release, and `creditToken` is permissionless, so a
     * third party can enlarge that figure at will. Against a token with a
     * fixed maximum per transfer, a single full-balance claim would then
     * revert and leave the recipient unable to draw any of it. Choosing the
     * amount keeps the aggregate from being a single point of failure, and
     * lets a recipient work around any per-transfer limit its quote asset
     * imposes.
     */
    function claimToken(address token, uint256 amount) external nonReentrant returns (uint256) {
        return _claimToken(token, amount);
    }

    /**
     * @dev Shared debit path for both native claim entry points.
     */
    function _claim(uint256 amount) private returns (uint256) {
        if (amount == 0) revert NoBalance();
        uint256 balance = _balances[msg.sender];
        if (amount > balance) revert InsufficientBalance(amount, balance);

        _balances[msg.sender] = balance - amount;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();

        emit Claimed(msg.sender, amount);
        return amount;
    }

    /**
     * @dev Shared debit path for both ERC-20 claim entry points.
     */
    function _claimToken(address token, uint256 amount) private returns (uint256) {
        if (amount == 0) revert NoBalance();
        uint256 balance = _tokenBalances[msg.sender][token];
        if (amount > balance) revert InsufficientBalance(amount, balance);

        _tokenBalances[msg.sender][token] = balance - amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit ClaimedToken(msg.sender, token, amount);
        return amount;
    }

    /**
     * @notice Returns the claimable native ETH balance for `recipient`.
     */
    function balanceOf(address recipient) external view returns (uint256) {
        return _balances[recipient];
    }

    /**
     * @notice Returns the claimable balance of `token` for `recipient`.
     */
    function balanceOfToken(address recipient, address token) external view returns (uint256) {
        return _tokenBalances[recipient][token];
    }
}
