// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PonsV2LaunchFactory} from "./PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "./PonsV2BondingCurve.sol";

/**
 * @title PonsV2LaunchAndBuy
 * @notice Creates a pons v2 launch and takes the first position on its curve
 * in a single transaction.
 *
 * PonsV2LaunchFactory cannot fold a developer buy into `launchToken`, so a
 * creator's first buy has to be a second transaction against a curve that is
 * already live and already public. The gap between the two is measured in
 * blocks for a bot and in seconds for a human holding a wallet prompt, and it
 * is long enough to lose the entire sellable allocation: a launch on this
 * factory had its curve bought out by twenty-two addresses in the two blocks
 * after it opened, leaving the creator with nothing.
 *
 * Routing both legs through this contract closes the gap outright rather than
 * narrowing it. The buy settles in the same transaction that created the
 * curve, so there is no intermediate state for anyone to trade against, and a
 * failed buy reverts the launch with it instead of stranding a token the
 * creator never wanted on its own.
 *
 * @dev This contract is the factory's trusted `launchForwarder`. It passes
 * its own caller to `launchTokenFor`, so CREATE2 addresses are namespaced by
 * the initiating account and the launch record attributes that account rather
 * than this router. The factory rejects calls to that entry point from every
 * other address, and the owner may rotate the forwarder when this periphery
 * contract is replaced.
 *
 * Access is the factory's own gate, applied to this contract's caller. This
 * trusted-forwarder role must not extend launch rights to every caller here
 * while the public gate is closed. The caller themselves must therefore pass
 * the factory's `canLaunch` predicate: the factory's whitelist remains the
 * single list governing direct and atomic launches.
 *
 * No balance is meant to persist between transactions. Both legs are funded by
 * the caller within the call and anything the curve hands back is returned to
 * them before it returns.
 */
contract PonsV2LaunchAndBuy is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NotApprovedLauncher();
    error NativeValueMismatch(uint256 sent, uint256 expected);
    error RefundFailed();

    event Launched(
        address indexed token,
        address indexed curve,
        address indexed recipient,
        address launcher,
        uint256 quoteSpent,
        uint256 tokensReceived
    );
    event Rescued(address indexed asset, address indexed recipient, uint256 amount);

    /// @notice Launch factory this contract creates tokens through.
    PonsV2LaunchFactory public immutable factory;

    /// @dev Holds this contract's caller to the factory's own launch gate,
    /// so the factory's whitelist is the single list governing launches on
    /// both paths and this contract's own whitelist slot there extends
    /// nothing to anyone.
    modifier onlyPermittedLauncher() {
        if (!factory.canLaunch(msg.sender)) revert NotApprovedLauncher();
        _;
    }

    constructor(PonsV2LaunchFactory factory_, address owner_) Ownable(owner_) {
        if (address(factory_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /**
     * @notice Launches a token and immediately buys `quoteIn` of its curve for
     * `recipient`, both in this transaction.
     *
     * @param params Launch parameters, forwarded to the factory untouched.
     * Set `creatorFeeRecipient` to the wallet that should earn the launch's
     * fees, and `expectedEconomics` to the value `previewLaunchEconomics`
     * returned, which still pins the terms as it would on a direct launch.
     * @param launchConfigId Factory launch config to launch against.
     * @param pairToken Quote asset, or the zero address for a native launch.
     * @param quoteIn Amount of the quote asset to spend on the opening buy. An
     * amount past what the curve can sell is clamped by the curve and the
     * remainder comes back to the caller.
     * @param minTokensOut Slippage bound on the opening buy. The curve prices
     * a clamped fill against this too, so a buy sized to take the whole
     * allocation can still set a meaningful floor.
     * @param recipient Receives the purchased tokens.
     * @param snipeTaxExemptions Additional wallets to exempt from the
     * launch-window snipe tax, for teams bundling their opening buys across
     * several addresses. `recipient` is appended automatically, so the dev
     * buy below always clears untaxed; pass an empty array when there is no
     * bundle. At most 31 entries: the factory bounds the combined list at
     * 32 including the appended recipient.
     *
     * @dev For a native launch the call must carry the launch fee and the buy
     * together. For an ERC-20 quote asset it carries the launch fee only, and
     * the buy is pulled from the caller, who must have approved this contract
     * for `quoteIn` first.
     */
    function launchAndBuy(
        PonsV2LaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable onlyPermittedLauncher nonReentrant returns (address token, address curve, uint256 tokensOut) {
        if (recipient == address(0)) revert ZeroAddress();
        // The atomic path keeps its payout routing explicit because the token
        // recipient, initiating account, and creator fee recipient may all be
        // different addresses.
        if (params.creatorFeeRecipient == address(0)) revert ZeroAddress();
        if (quoteIn == 0) revert ZeroAmount();

        uint256 launchFee = factory.launchFee();
        bool nativeQuote = pairToken == address(0);

        // Balance held before this call funds itself, measured on the leg
        // the curve refunds in: native for a native launch, the quote token
        // otherwise. The refund is measured against this rather than swept
        // wholesale, so dust left behind by an earlier caller is never paid
        // out to this one.
        uint256 balanceBefore =
            nativeQuote ? address(this).balance - msg.value : IERC20(pairToken).balanceOf(address(this));

        uint256 expectedValue = nativeQuote ? launchFee + quoteIn : launchFee;
        if (msg.value != expectedValue) revert NativeValueMismatch(msg.value, expectedValue);

        if (!nativeQuote) {
            IERC20(pairToken).safeTransferFrom(msg.sender, address(this), quoteIn);
        }

        // The dev buy lands in the launch second, exactly when the snipe tax
        // peaks, so its recipient joins the exemption list whether or not
        // the caller declared them.
        address[] memory exemptions = new address[](snipeTaxExemptions.length + 1);
        for (uint256 i = 0; i < snipeTaxExemptions.length; ++i) {
            exemptions[i] = snipeTaxExemptions[i];
        }
        exemptions[snipeTaxExemptions.length] = recipient;

        (token, curve) =
        factory.launchTokenFor{value: launchFee}(params, launchConfigId, pairToken, msg.sender, exemptions);

        if (nativeQuote) {
            tokensOut = PonsV2BondingCurve(payable(curve)).buy{value: quoteIn}(quoteIn, minTokensOut, recipient);
        } else {
            IERC20(pairToken).forceApprove(curve, quoteIn);
            tokensOut = PonsV2BondingCurve(payable(curve)).buy(quoteIn, minTokensOut, recipient);
            // A clamped fill leaves the unused allowance standing.
            IERC20(pairToken).forceApprove(curve, 0);
        }

        _refund(pairToken, nativeQuote, balanceBefore);

        emit Launched(token, curve, recipient, msg.sender, quoteIn, tokensOut);
    }

    /**
     * @notice Sends a stranded balance to `recipient`.
     * @dev A launch funds and empties itself within one call, so this covers
     * only what arrives outside that path, such as a transfer sent here by
     * mistake or a refund whose return leg failed.
     */
    function rescue(address asset, address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 amount;
        if (asset == address(0)) {
            amount = address(this).balance;
            if (amount == 0) revert ZeroAmount();
            (bool sent,) = payable(recipient).call{value: amount}("");
            if (!sent) revert RefundFailed();
        } else {
            amount = IERC20(asset).balanceOf(address(this));
            if (amount == 0) revert ZeroAmount();
            IERC20(asset).safeTransfer(recipient, amount);
        }

        emit Rescued(asset, recipient, amount);
    }

    /**
     * @dev Returns whatever the curve handed back for a buy it could not fill
     * in full. The curve refunds to its caller, which is this contract, so the
     * excess would otherwise settle here rather than with the launcher who
     * paid it.
     */
    function _refund(address pairToken, bool nativeQuote, uint256 balanceBefore) private {
        if (nativeQuote) {
            uint256 refund = address(this).balance - balanceBefore;
            if (refund == 0) return;
            (bool sent,) = payable(msg.sender).call{value: refund}("");
            if (!sent) revert RefundFailed();
            return;
        }

        uint256 quoteRefund = IERC20(pairToken).balanceOf(address(this)) - balanceBefore;
        if (quoteRefund == 0) return;
        IERC20(pairToken).safeTransfer(msg.sender, quoteRefund);
    }

    /**
     * @notice Accepts the native refund a partially filled curve returns.
     */
    receive() external payable {}
}
