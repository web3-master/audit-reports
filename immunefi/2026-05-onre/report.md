## Title
update_offer_fee allows up to 100% fee (cap bypass)

## Summary
At offer creation time the fee is capped at MAX_ALLOWED_FEE_BPS = 1000 (10%), and the redemption side enforces the same cap on both create and update. However, update_offer_fee mistakenly validates against MAX_BASIS_POINTS = 10000 (100%), so the boss can raise the fee to 100% after users have started using an offer. With fee_basis_points = 10_000 the user transfers their full token_in_amount but the net amount sent into the price formula is 0 → user receives 0 token_out.


## Vulnerability Detail
When the new offer is created, the offer fee is limited by `MAX_ALLOWED_FEE_BPS`.
```rust
File: make_offer.rs
129: pub fn make_offer(
130:     ctx: Context<MakeOffer>,
131:     fee_basis_points: u16,
132:     needs_approval: bool,
133:     allow_permissionless: bool,
134: ) -> Result<()> {
135:     // Validate fee is within valid range (0-10000 basis points = 0-100%)
136:     require!(
137:         fee_basis_points <= MAX_ALLOWED_FEE_BPS,
138:         MakeOfferErrorCode::InvalidFee
139:     );
...
163: }
```

However, in the following update_offer_fee() function, the new offer fee is limited by `MAX_BASIS_POINTS`.
```rust
File: update_offer_fee.rs
096: pub fn update_offer_fee(ctx: Context<UpdateOfferFee>, new_fee_basis_points: u16) -> Result<()> {
097:     // Validate fee is within valid range (0-10000 basis points = 0-100%)
098:     require!(
099:         new_fee_basis_points <= MAX_BASIS_POINTS,
100:         UpdateOfferFeeErrorCode::InvalidFee
101:     );
...
126: }
```


## Impact
Loss of user funds:
Taker understand that their max allowed fee is MAX_ALLOWED_FEE_BPS.
But in fact, the offer can charge more than this as fee.
This means loss of taker's fund.

## Code Snippet
https://github.com/onre-finance/onre-sol/blob/361cd588ba48b89a44236801140cdc2b5d110251/programs/onreapp/src/instructions/offer/update_offer_fee.rs#L99

## Recommendation
Use the same `MAX_ALLOWED_FEE_BPS` constant as every other fee path.
```rust
require!(
    new_fee_basis_points <= MAX_ALLOWED_FEE_BPS,
    UpdateOfferFeeErrorCode::InvalidFee
);
```