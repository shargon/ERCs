// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC20WindowLimits} from "../../IERC20WindowLimits.sol";

/// Test fixture only, not a production token or a proposed mandatory implementation.
/// Supply is assigned once so that no privileged debit path is needed by the harness.
contract WindowToken is IERC20WindowLimits {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    mapping(address => LimitPolicy) private policies;
    mapping(address => PendingLimits) private pending;
    mapping(address => uint256) private spentEpoch;
    mapping(address => uint256) private spentAmount;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address holder, uint256 supply) {
        require(holder != address(0));
        balanceOf[holder] = supply;
        totalSupply = supply;
        emit Transfer(address(0), holder, supply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        move(from, to, amount);
        return true;
    }

    function move(address from, address to, uint256 amount) private {
        require(to != address(0));
        debit(from, amount);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function burn(uint256 amount) external {
        debit(msg.sender, amount);
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function debit(address from, uint256 amount) private {
        LimitPolicy storage p = policies[from];
        if (!p.enrolled || amount == 0) return;
        uint256 epoch = block.number / p.windowBlocks;
        uint256 used = spentEpoch[from] == epoch ? spentAmount[from] : 0;
        require(amount <= p.maxTransfer && used + amount <= p.maxWindow, "outgoing limit");
        spentEpoch[from] = epoch;
        spentAmount[from] = used + amount;
        emit WindowSpent(from, epoch, amount, used + amount);
    }

    function enrollLimits(uint256 t, uint256 q, uint256 w, uint256 d, address guardian) external {
        require(!policies[msg.sender].enrolled && t <= q && w > 0 && d > 0);
        require(guardian != address(0) && guardian != msg.sender);
        policies[msg.sender] = LimitPolicy(true, guardian, w, d, t, q);
        emit LimitsEnrolled(msg.sender, guardian, w, d, t, q);
    }

    function authorized(address account) private view {
        require(policies[account].enrolled);
        require(msg.sender == account || msg.sender == policies[account].guardian);
    }

    function cancel(address account) private {
        if (pending[account].exists) {
            delete pending[account];
            emit LimitsCancelled(account, msg.sender);
        }
    }

    function tightenLimits(address account, uint256 t, uint256 q) external {
        authorized(account);
        LimitPolicy storage p = policies[account];
        require(t <= q && t <= p.maxTransfer && q <= p.maxWindow);
        cancel(account);
        p.maxTransfer = t;
        p.maxWindow = q;
        emit LimitsChanged(account, t, q);
    }

    function scheduleLimits(uint256 t, uint256 q) external {
        LimitPolicy storage p = policies[msg.sender];
        require(p.enrolled && t <= q);
        uint256 activateBlock = block.number + p.changeDelayBlocks;
        cancel(msg.sender);
        pending[msg.sender] = PendingLimits(true, t, q, activateBlock);
        emit LimitsScheduled(msg.sender, t, q, activateBlock);
    }

    function cancelLimits(address account) external {
        authorized(account);
        cancel(account);
    }

    function applyLimits(address account) external {
        PendingLimits memory next = pending[account];
        require(next.exists && block.number >= next.activateBlock);
        policies[account].maxTransfer = next.maxTransfer;
        policies[account].maxWindow = next.maxWindow;
        delete pending[account];
        emit LimitsChanged(account, next.maxTransfer, next.maxWindow);
    }

    function limitPolicy(address account) external view returns (LimitPolicy memory) {
        return policies[account];
    }

    function pendingLimits(address account) external view returns (PendingLimits memory) {
        return pending[account];
    }

    function windowUsage(address account)
        external
        view
        returns (uint256 epoch, uint256 spent, uint256 remaining, uint256 nextResetBlock)
    {
        LimitPolicy storage p = policies[account];
        if (!p.enrolled) return (0, 0, type(uint256).max, 0);
        epoch = block.number / p.windowBlocks;
        spent = spentEpoch[account] == epoch ? spentAmount[account] : 0;
        remaining = p.maxWindow > spent ? p.maxWindow - spent : 0;
        nextResetBlock = (epoch + 1) * p.windowBlocks;
    }
}
