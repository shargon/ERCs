// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

interface IERC20WindowLimits {
    /// @dev Limits use raw token units. Window length, delay and guardian are immutable.
    struct LimitPolicy {
        bool enrolled;
        address guardian;
        uint256 windowBlocks;
        uint256 changeDelayBlocks;
        uint256 maxTransfer;
        uint256 maxWindow;
    }
    struct PendingLimits {
        bool exists;
        uint256 maxTransfer;
        uint256 maxWindow;
        uint256 activateBlock;
    }
    event LimitsEnrolled(address indexed account, address indexed guardian, uint256 windowBlocks, uint256 changeDelayBlocks, uint256 maxTransfer, uint256 maxWindow);
    event LimitsChanged(address indexed account, uint256 maxTransfer, uint256 maxWindow);
    event LimitsScheduled(address indexed account, uint256 maxTransfer, uint256 maxWindow, uint256 activateBlock);
    event LimitsCancelled(address indexed account, address indexed actor);
    event WindowSpent(address indexed account, uint256 indexed epoch, uint256 amount, uint256 totalSpent);
    /// @notice Enroll msg.sender once. Require maxTransfer <= maxWindow, positive
    /// windowBlocks/changeDelayBlocks and a nonzero guardian distinct from msg.sender.
    /// @dev Fixed epoch = floor(block.number / windowBlocks); NOT a sliding window.
    function enrollLimits(uint256 maxTransfer, uint256 maxWindow, uint256 windowBlocks, uint256 changeDelayBlocks, address guardian) external;
    /// @notice Holder or guardian may reduce either cap immediately (including zero).
    /// @dev Neither cap may increase. Cancels pending change, NEVER resets usage.
    function tightenLimits(address account, uint256 maxTransfer, uint256 maxWindow) external;
    /// @notice Holder schedules replacement caps after its immutable change delay.
    /// @dev Replaces pending change and restarts the full delay; usage is preserved.
    function scheduleLimits(uint256 maxTransfer, uint256 maxWindow) external;
    /// @notice Holder or guardian vetoes a pending change; no pending change is a no-op.
    function cancelLimits(address account) external;
    /// @notice Anyone may apply a matured change; no automatic activation.
    /// @dev MUST preserve usage. Reverts when absent or before activateBlock.
    function applyLimits(address account) external;
    /// @notice Current effective policy (pending changes are returned separately).
    function limitPolicy(address account) external view returns (LimitPolicy memory);
    /// @notice All-zero struct if no pending change exists.
    function pendingLimits(address account) external view returns (PendingLimits memory);
    /// @notice Current epoch usage; remaining is max(0, maxWindow - spent).
    /// @dev Unenrolled returns (0,0,type(uint256).max,0). Remaining ignores balance,
    /// per-transfer cap and independent restrictions. Expired usage reads as zero.
    function windowUsage(address account) external view returns (uint256 epoch, uint256 spent, uint256 remaining, uint256 nextResetBlock);
}
