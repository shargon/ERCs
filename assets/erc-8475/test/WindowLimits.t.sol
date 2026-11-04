// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC20WindowLimits} from "../IERC20WindowLimits.sol";
import {WindowToken} from "./fixtures/WindowToken.sol";

interface Vm {
    function roll(uint256) external;
    function prank(address) external;
    function expectRevert() external;
}

interface IWindowToken is IERC20WindowLimits {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// Test-only consumer with a separate budget and an application revision counter.
/// This models enclosing state; it is NOT an implementation of ERC-8427 or ERC-8448.
contract AtomicConsumer {
    IWindowToken public immutable token;
    uint256 public used;
    uint256 public revision;
    uint256 public immutable budget;

    constructor(IWindowToken token_, uint256 budget_) {
        token = token_;
        budget = budget_;
    }

    function spend(address holder, address recipient, uint256 amount, bool failAfter) external {
        execute(holder, recipient, amount);
        require(!failAfter, "later application failure");
    }

    function batch(address holder, address recipient, uint256 first, uint256 second) external {
        execute(holder, recipient, first);
        execute(holder, recipient, second);
    }

    function execute(address holder, address recipient, uint256 amount) private {
        require(used + amount <= budget, "consumer budget");
        used += amount;
        revision++;
        require(token.transferFrom(holder, recipient, amount));
    }
}

/// Reusable behavioral tests: override deployFundedToken to run against another token.
/// The adapter must return an unenrolled holder with exactly `supply` units.
abstract contract WindowLimitsChecks {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant HOLDER = address(0x100);
    address internal constant GUARDIAN = address(0x200);
    address internal constant AGENT_A = address(0x300);
    address internal constant AGENT_B = address(0x400);
    address internal constant RECIPIENT = address(0x500);
    IWindowToken internal token;

    function deployFundedToken(address holder, uint256 supply) internal virtual returns (IWindowToken);

    function setUp() public virtual {
        vm.roll(100);
        token = deployFundedToken(HOLDER, 1000);
    }

    function enroll(uint256 t, uint256 q) internal {
        vm.prank(HOLDER);
        token.enrollLimits(t, q, 10, 5, GUARDIAN);
    }

    function approve(address spender, uint256 amount) internal {
        vm.prank(HOLDER);
        require(token.approve(spender, amount));
    }

    function send(uint256 amount) internal {
        vm.prank(HOLDER);
        require(token.transfer(RECIPIENT, amount));
    }

    function usage(uint256 spent, uint256 remaining) internal view {
        (uint256 e, uint256 s, uint256 r, uint256 reset) = token.windowUsage(HOLDER);
        require(e == block.number / 10 && reset == (e + 1) * 10, "window bounds");
        require(s == spent && r == remaining, "window usage");
    }

    function assertUntouched(AtomicConsumer consumer, uint256 approved) internal view {
        require(consumer.used() == 0 && consumer.revision() == 0, "consumer state consumed");
        require(token.balanceOf(HOLDER) == 1000 && token.balanceOf(RECIPIENT) == 0, "balances changed");
        require(token.allowance(HOLDER, address(consumer)) == approved, "allowance consumed");
    }

    function test_twoAgentsShareTheHoldersCounter() public {
        enroll(60, 100);
        approve(AGENT_A, 100);
        approve(AGENT_B, 100);
        vm.prank(AGENT_A);
        require(token.transferFrom(HOLDER, RECIPIENT, 60));
        vm.prank(AGENT_B);
        require(token.transferFrom(HOLDER, RECIPIENT, 40));
        usage(100, 0);
        vm.prank(AGENT_B);
        vm.expectRevert();
        token.transferFrom(HOLDER, RECIPIENT, 1);
        usage(100, 0);
        require(token.allowance(HOLDER, AGENT_B) == 60, "failed call consumed allowance");
    }

    function testFuzz_twoAgentsCannotSplitAroundWindowCap(uint8 a, uint8 b) public {
        uint256 first = 1 + uint256(a) % 60;
        uint256 second = 1 + uint256(b) % 60;
        enroll(60, 100);
        approve(AGENT_A, 100);
        approve(AGENT_B, 100);
        vm.prank(AGENT_A);
        require(token.transferFrom(HOLDER, RECIPIENT, first));
        vm.prank(AGENT_B);
        if (first + second > 100) {
            vm.expectRevert();
            token.transferFrom(HOLDER, RECIPIENT, second);
            usage(first, 100 - first);
            require(token.allowance(HOLDER, AGENT_B) == 100, "failed spender allowance");
        } else {
            require(token.transferFrom(HOLDER, RECIPIENT, second));
            usage(first + second, 100 - first - second);
        }
    }

    function test_tokenQuotaFailureRollsBackEnclosingBudgetAndRevision() public {
        enroll(100, 100);
        send(50);
        AtomicConsumer consumer = new AtomicConsumer(token, 80);
        approve(address(consumer), 80);
        // The consumer authorizes 80; the holder has only 50 token units left in this epoch.
        vm.expectRevert();
        consumer.spend(HOLDER, RECIPIENT, 80, false);
        usage(50, 50);
        require(consumer.used() == 0 && consumer.revision() == 0, "enclosing state consumed");
        require(token.allowance(HOLDER, address(consumer)) == 80, "allowance consumed");
        require(token.balanceOf(HOLDER) == 950 && token.balanceOf(RECIPIENT) == 50, "balances changed");
    }

    function test_laterApplicationFailureRollsBackSuccessfulTokenTransfer() public {
        enroll(60, 100);
        AtomicConsumer consumer = new AtomicConsumer(token, 80);
        approve(address(consumer), 80);
        vm.expectRevert();
        consumer.spend(HOLDER, RECIPIENT, 60, true);
        usage(0, 100);
        assertUntouched(consumer, 80);
        // The same authorization remains usable after the failed transaction.
        consumer.spend(HOLDER, RECIPIENT, 60, false);
        usage(60, 40);
        require(consumer.used() == 60 && consumer.revision() == 1, "retry state");
        require(token.allowance(HOLDER, address(consumer)) == 20, "retry allowance");
    }

    function test_secondBatchMovementFailureRollsBackFirst() public {
        enroll(60, 100);
        AtomicConsumer consumer = new AtomicConsumer(token, 200);
        approve(address(consumer), 200);
        vm.expectRevert();
        consumer.batch(HOLDER, RECIPIENT, 60, 50);
        usage(0, 100);
        assertUntouched(consumer, 200);
    }

    function test_perTransferCapIsNotAppliedToOuterBatchTotal() public {
        enroll(60, 100);
        AtomicConsumer consumer = new AtomicConsumer(token, 200);
        approve(address(consumer), 200);
        consumer.batch(HOLDER, RECIPIENT, 60, 40);
        usage(100, 0);
        require(consumer.used() == 100 && consumer.revision() == 2, "batch state");
        require(token.balanceOf(RECIPIENT) == 100, "batch balance");
    }

    function test_perTransferCapStillAppliesWithEnoughWindowQuota() public {
        enroll(60, 100);
        vm.prank(HOLDER);
        vm.expectRevert();
        token.transfer(RECIPIENT, 61);
        usage(0, 100);
    }

    function test_failedBalanceCheckPreservesQuotaAndAllowance() public {
        enroll(2000, 2000);
        approve(AGENT_A, 2000);
        vm.prank(AGENT_A);
        vm.expectRevert();
        token.transferFrom(HOLDER, RECIPIENT, 1001);
        usage(0, 2000);
        require(token.allowance(HOLDER, AGENT_A) == 2000, "allowance consumed");
        require(token.balanceOf(HOLDER) == 1000 && token.balanceOf(RECIPIENT) == 0, "balances changed");
    }

    function test_refundDoesNotRefillSpentQuota() public {
        enroll(100, 100);
        send(100);
        vm.prank(RECIPIENT);
        require(token.transfer(HOLDER, 100));
        usage(100, 0);
        require(token.balanceOf(HOLDER) == 1000, "refund balance");
        vm.prank(HOLDER);
        vm.expectRevert();
        token.transfer(RECIPIENT, 1);
    }

    function test_selfTransferConsumesGrossAmount() public {
        enroll(60, 100);
        vm.prank(HOLDER);
        require(token.transfer(HOLDER, 60));
        usage(60, 40);
        require(token.balanceOf(HOLDER) == 1000, "self-transfer balance");
    }

    function test_approvalsDoNotReserveQuota() public {
        enroll(60, 100);
        approve(AGENT_A, 1000);
        approve(AGENT_B, 1000);
        usage(0, 100);
        approve(AGENT_A, 0);
        usage(0, 100);
    }

    function test_boundaryResetsLogicalUsageWithoutTransaction() public {
        enroll(100, 100);
        vm.roll(109);
        send(100);
        vm.roll(110);
        usage(0, 100);
        send(100);
        usage(100, 0);
    }

    function test_tighteningBelowSpentPreservesUsageAndCancelsPending() public {
        enroll(60, 100);
        send(60);
        vm.prank(HOLDER);
        token.scheduleLimits(100, 200);
        vm.prank(GUARDIAN);
        token.tightenLimits(HOLDER, 40, 40);
        usage(60, 0);
        require(!token.pendingLimits(HOLDER).exists, "pending change survived tightening");
        vm.prank(HOLDER);
        vm.expectRevert();
        token.transfer(RECIPIENT, 1);
    }

    function test_maturityNeedsExplicitApplicationAndPreservesUsage() public {
        enroll(60, 100);
        send(60);
        vm.prank(HOLDER);
        token.scheduleLimits(100, 200);
        vm.roll(104);
        vm.expectRevert();
        token.applyLimits(HOLDER);
        vm.roll(105);
        require(token.limitPolicy(HOLDER).maxWindow == 100, "automatic activation");
        require(token.pendingLimits(HOLDER).exists, "matured change lost");
        usage(60, 40);
        vm.prank(AGENT_B); // anyone can apply
        token.applyLimits(HOLDER);
        usage(60, 140);
        require(!token.pendingLimits(HOLDER).exists, "applied change remains pending");
    }

    function test_reschedulingRestartsDelay() public {
        enroll(60, 100);
        vm.prank(HOLDER);
        token.scheduleLimits(100, 200);
        vm.roll(104);
        vm.prank(HOLDER);
        token.scheduleLimits(100, 300);
        require(token.pendingLimits(HOLDER).activateBlock == 109, "delay not restarted");
        vm.roll(105);
        vm.expectRevert();
        token.applyLimits(HOLDER);
    }

    function test_guardianMayCancelMaturedUnappliedChange() public {
        enroll(60, 100);
        send(60);
        vm.prank(HOLDER);
        token.scheduleLimits(100, 200);
        vm.roll(105);
        vm.prank(GUARDIAN);
        token.cancelLimits(HOLDER);
        vm.expectRevert();
        token.applyLimits(HOLDER);
        usage(60, 40);
    }

    function test_guardianCannotRelaxAndOtherSpenderCannotTighten() public {
        enroll(60, 100);
        vm.prank(GUARDIAN);
        vm.expectRevert();
        token.tightenLimits(HOLDER, 60, 101);
        vm.prank(AGENT_A);
        vm.expectRevert();
        token.tightenLimits(HOLDER, 0, 0);
        vm.prank(AGENT_A);
        vm.expectRevert();
        token.cancelLimits(HOLDER);
    }

    function test_zeroTransferRemainsPossibleWithZeroCaps() public {
        enroll(0, 0);
        send(0);
        usage(0, 0);
        vm.prank(HOLDER);
        vm.expectRevert();
        token.transfer(RECIPIENT, 1);
    }

    function test_reEnrollmentCannotResetUsageOrChangeWindow() public {
        enroll(60, 100);
        send(60);
        vm.prank(HOLDER);
        vm.expectRevert();
        token.enrollLimits(100, 200, 1, 1, GUARDIAN);
        usage(60, 40);
        IERC20WindowLimits.LimitPolicy memory p = token.limitPolicy(HOLDER);
        require(p.windowBlocks == 10 && p.changeDelayBlocks == 5 && p.guardian == GUARDIAN, "immutable fields");
    }

    function test_unenrolledQueryIsDistinctFromEnrolledZeroCaps() public {
        (uint256 e, uint256 s, uint256 r, uint256 reset) = token.windowUsage(HOLDER);
        require(e == 0 && s == 0 && r == type(uint256).max && reset == 0, "unenrolled query");
        require(!token.limitPolicy(HOLDER).enrolled, "unexpected enrollment");
        enroll(0, 0);
        require(token.limitPolicy(HOLDER).enrolled, "missing enrollment");
        usage(0, 0);
    }
}

contract WindowLimitsFixtureTest is WindowLimitsChecks {
    function deployFundedToken(address holder, uint256 supply) internal override returns (IWindowToken) {
        return IWindowToken(address(new WindowToken(holder, supply)));
    }

    // Burning is an optional token entry point, not a method of IERC20WindowLimits.
    function test_fixtureBurnSharesTransferBudget() public {
        enroll(60, 100);
        send(60);
        vm.prank(HOLDER);
        WindowToken(address(token)).burn(40);
        usage(100, 0);
        vm.prank(HOLDER);
        vm.expectRevert();
        WindowToken(address(token)).burn(1);
        require(token.balanceOf(HOLDER) == 900, "burn balance");
    }
}
