## Title
Arbitrary buffer account closure & rent theft in `buffer-payload::execute`

## Brief
The `execute` instruction allows any signer to close an arbitrary completed `Buffer` PDA owned by the `buffer-payload` program and redirect the rent lamports to themselves. The buffer account passed in `remaining_accounts` is not constrained to belong to the calling `authority`.

## Vulnerability Details

[contracts/programs/buffer-payload/src/lib.rs:25-48](contracts/programs/buffer-payload/src/lib.rs#L25-L48):

```rust
pub fn execute<'info>(
    ctx: Context<'_, '_, 'info, 'info, ExecuteContext<'info>>,
    report: Vec<u8>,
    fail: bool,
) -> Result<()> {
    if report.is_empty() {
        require!(!fail, Error::ForcedFailure);
        let (_, buffered_bytes) = deserialize_from_buffer_account(
            ctx.remaining_accounts.last().ok_or(Error::ReportUnavailable)?,
        )?;

        let buffer = Account::<Buffer>::try_from(ctx.remaining_accounts.last().unwrap())?;
        require!(buffer.is_complete(), Error::Incomplete);
        let report_length = buffer.report_length.try_into().unwrap();
        require!(buffered_bytes == report_length, Error::Incomplete);

        buffer.close(ctx.accounts.authority.to_account_info())?;   // <-- attacker becomes rent recipient
    }
    Ok(())
}
```

`ExecuteContext` only declares `authority: Signer` and the system program; the buffer account is fetched from `remaining_accounts.last()` with no constraint check:

[contracts/programs/buffer-payload/src/lib.rs:87-92](contracts/programs/buffer-payload/src/lib.rs#L87-L92):

```rust
#[derive(Accounts)]
pub struct ExecuteContext<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}
```

Compare with the legitimate close path which *does* tie the PDA seeds to the caller:

[contracts/programs/buffer-payload/src/lib.rs:118-126](contracts/programs/buffer-payload/src/lib.rs#L118-L126):

```rust
pub struct CloseBufferContext<'info> {
    #[account(
        mut,
        seeds = [EXECUTION_REPORT_BUFFER, &buffer_id, authority.key().as_ref()],
        bump,
        close = authority
    )]
    pub buffer: Account<'info, Buffer>,
    ...
}
```

`deserialize_from_buffer_account` only verifies the account's *program owner* equals `crate::ID` ([buffering.rs:140-143](contracts/programs/buffer-payload/src/buffering.rs#L140-L143)) — it does **not** verify the PDA was derived with the caller's `authority.key()` as a seed.

## Exploit Flow
1. Victim `V` calls `buffer_execution_report` repeatedly to populate a buffer at PDA `[EXECUTION_REPORT_BUFFER, buffer_id, V]`. Buffer is funded with rent lamports paid by `V`.
2. Attacker `A` observes the public `buffer_id` and `V`'s pubkey on-chain.
3. Attacker `A` calls `execute(report = vec![], fail = false)`, marking the victim's buffer PDA as `writable` in the transaction and passing it as the last remaining account, with `A`'s pubkey as `authority`.
4. `deserialize_from_buffer_account` passes (owner == buffer-payload program ID).
5. `buffer.is_complete()` passes for any completed buffer.
6. `buffer.close(A.authority)` — rent lamports transfer to attacker, buffer is wiped.

## Impact — CRITICAL
- Direct theft of SOL (the rent reserve) from any user with a completed buffer.
- Destruction of off-chain workflow report data immediately before consumption, enabling denial-of-service against downstream consumers that depend on the buffered payload.
- The attack is permissionless and griefable at scale because completed buffers are discoverable from chain history.

## Recommended Fix
Either constrain the buffer in the `ExecuteContext` to match the caller's seeds, or remove the `close` from `execute` entirely (closing already has a dedicated, properly-constrained instruction in `close_execution_report_buffer`). A minimal fix:

```rust
#[derive(Accounts)]
#[instruction(report: Vec<u8>, fail: bool, buffer_id: Vec<u8>)]
pub struct ExecuteContext<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(
        mut,
        seeds = [EXECUTION_REPORT_BUFFER, &buffer_id, authority.key().as_ref()],
        bump,
        close = authority,
    )]
    pub buffer: Option<Account<'info, Buffer>>,
    pub system_program: Program<'info, System>,
}
```

…and read the buffer from `ctx.accounts.buffer` instead of `remaining_accounts.last()`.

## References
https://github.com/smartcontractkit/chainlink-solana/blob/f71b70a4d0206c31ac0f498da98d7ba050df279e/contracts/programs/buffer-payload/src/lib.rs#L44