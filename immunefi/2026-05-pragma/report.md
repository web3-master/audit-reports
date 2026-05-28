## Title
Permanent Freezing of `callback_fee` Funds in `Randomness.submit_random`

## Brief / Intro
The `Randomness` contract is the only contract that custodies ERC-20 tokens (it pools all users' deposits). The fee-settlement logic in `submit_random` mis-accounts the funds collected at request time, so a fixed portion of every fulfilled request — the `callback_fee` (the operator's actual execution cost) — is left in the contract with **no code path able to ever move it out**. These tokens are permanently frozen.

## Vulnerability Details
File: [pragma-oracle/src/randomness/randomness.cairo](pragma-oracle/src/randomness/randomness.cairo)

At request time, the full amount pulled from the user is:

```cairo
// request_random (lines ~261-289)
let total_fee: u256 = wei_premium_fee.into() + callback_fee_limit.into();
token_dispatcher.transferFrom(caller_address, contract_address, total_fee);
self.total_fees.write((caller_address, request_id), total_fee);   // = wei_premium_fee + callback_fee_limit
```

At fulfilment time, the settlement is:

```cairo
// submit_random (lines ~388-422)
// pay callback_fee_limit - callback_fee
token_dispatcher.transfer(callback_address, (callback_fee_limit - callback_fee).into());
...
let total_fees = self.total_fees.read((requestor_address, request_id)); // = wei_premium_fee + callback_fee_limit
let actual_balance = self.admin_fees.read();
self.admin_fees.write(actual_balance + (total_fees - callback_fee_limit.into())); // += wei_premium_fee ONLY
```

Accounting per fulfilled request:

```
Deposited by user      : wei_premium_fee + callback_fee_limit
Refunded to callback   : callback_fee_limit - callback_fee
Credited to admin_fees : (wei_premium_fee + callback_fee_limit) - callback_fee_limit = wei_premium_fee
-----------------------------------------------------------------------------------------------------
Unaccounted (stuck)    : callback_fee
```

The `callback_fee` (the actual, off-chain–estimated execution cost the operator spent) is **neither** refunded to the user **nor** credited to `admin_fees`. The only withdrawal path, `withdraw_funds`, can only move `admin_fees`:

```cairo
// withdraw_funds (lines ~525-535)
let balance = self.admin_fees.read();
self.admin_fees.write(0);
token_dispatcher.transfer(receiver_address, balance);   // only ever withdraws admin_fees
```

Because the request's status is now `FULFILLED`, `cancel_random_request` (requires `!= FULFILLED`) and `refund_operation` (requires `OUT_OF_GAS`) are both blocked, and `update_status` cannot move a `FULFILLED` request. Consequently the `callback_fee` portion of **every** fulfilled request accumulates in the contract balance with **no reachable code path to retrieve it**.

## Impact Details / Severity
** Permanent freezing of funds **
- Every successful `submit_random` permanently locks `callback_fee` worth of the payment token inside the contract.
- The loss is unbounded over time and scales linearly with usage; the operator is systematically under-reimbursed for gas and the locked tokens can never be recovered (short of an upgrade), even by the admin.
- This is a deterministic accounting error, not a trust assumption — it triggers on the normal, intended fulfilment path.

## Recommended Fix / Mitigation
Credit the operator's actual execution cost to `admin_fees` (or transfer it to the operator) so the full deposit is accounted for. For example:

```cairo
// refund the unused budget to the caller…
token_dispatcher.transfer(callback_address, (callback_fee_limit - callback_fee).into());
// …and credit BOTH the premium AND the consumed callback_fee to the protocol:
self.admin_fees.write(actual_balance + (total_fees - (callback_fee_limit - callback_fee).into()));
```

Add an invariant test asserting, for each fulfilled request, that
`refund_paid + admin_credit == total_fees` (i.e. nothing is silently stranded), and zero out `total_fees[(requestor, request_id)]` on fulfilment for clarity.

## References
https://github.com/astraly-labs/pragma-oracle/blob/b02ad9e4f9312e554d602b8d87fc0065d104891b/pragma-oracle/src/randomness/randomness.cairo#L422