# Outgoing window-limit composition tests

This standalone Foundry package makes a subset of ERC-8475's accounting and policy
rules executable. It includes the draft interface, reusable behavioral checks, a
small test token, and an enclosing consumer with its own budget and revision counter.
There are no external Solidity dependencies.

From the repository root:

```sh
cd assets/erc-8475
forge test
```

Validated with Forge 1.7.1 and Solidity 0.8.24: 21 tests pass, including one fuzz test
with 256 runs. The tests cover:

- Two independently approved spenders sharing one holder's aggregate counter.
- A consumer that authorizes 80 while only 50 remains in the token's window: the
  failed transfer preserves the consumer's budget/revision, allowance and balances.
- A later application failure reverting a successful token transfer and its quota
  usage; retrying the same authorization then succeeds.
- A second batch movement exceeding the window cap and reverting the first one.
- Per-movement limits allowing a valid batch whose total exceeds the per-transfer cap.
- Insufficient balance, self-transfers, refunds, approvals, and zero transfers.
- Logical window resets, tightening below spent usage, delayed application,
  rescheduling, guardian veto, and immutable enrollment parameters.
- Burns sharing the counter, tested separately against the included fixture.

## Testing another implementation

Import `test/WindowLimits.t.sol`, inherit `WindowLimitsChecks`, and override
`deployFundedToken(address holder, uint256 supply)`. Return the implementation's
address as `IWindowToken`, with the holder unenrolled and funded with exactly that
supply. Keep the tests unchanged. The burn test belongs to `WindowLimitsFixtureTest`
because burning is an optional token entry point, not a standardized window-limit
method.

`WindowToken` and `AtomicConsumer` are test fixtures, not production implementations.
The consumer's independent budget only models enclosing application state: these
tests do not execute ERC-8427 grants or ERC-8448 orders. Passing the fixture suite is
not evidence that another implementation conforms. The package does not cover every
normative rule, event ordering, signature-based debit paths, callbacks, fees, rebasing,
or all arithmetic boundaries. Those need implementation-specific checks.

The interface follows the draft at commit
`ae22e499eed624a83e6edf6c06d8ba632295500a`. No interface or normative text changes are
proposed here. Files are CC0-1.0, matching the proposal assets.
