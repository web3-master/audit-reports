// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "forge-std/Test.sol";

import { VaultsBaseTest } from "./vaults.t.sol";
import { Error as FluidVaultError } from "../../../../contracts/protocols/vault/error.sol";
import { ErrorTypes as FluidVaultErrorTypes } from "../../../../contracts/protocols/vault/errorTypes.sol";
import { Error as FluidDexError } from "../../../../contracts/protocols/dex/error.sol";
import { ErrorTypes as FluidDexErrorTypes } from "../../../../contracts/protocols/dex/errorTypes.sol";

contract test_T2T4_SlippageBypass is VaultsBaseTest {
    function _wei0(uint256 amount_) internal view returns (int256) {
        return int256(amount_ * DAI_USDC_VAULT.dex.token0Wei);
    }
    function _wei1(uint256 amount_) internal view returns (int256) {
        return int256(amount_ * DAI_USDC_VAULT.dex.token1Wei);
    }

    function test_T2_colToken1MinMax_validationBypassed() public {
        int256 perfectShares  = 100 * 1e18;
        int256 token0Cap      = _wei0(105);
        int256 token1Cap      = int256(-1);          // <= 0  →  must revert per comment

        // expected behaviour: revert with VaultDex__InvalidOperateAmount.
        // actual behaviour (bug): no revert here.
        vm.prank(alice);
        (uint256 nftId, int256[] memory r) = DAI_USDC_VAULT.vaultT2.operatePerfect(
            0,
            perfectShares,
            token0Cap,
            token1Cap,                                // <— bypasses guard
            int256(0),
            alice
        );

        // Position was created → call did NOT revert at the slippage guard.
        assertGt(nftId, 0, "deposit unexpectedly reverted");
        // r[1] = token0 deposited, r[2] = token1 deposited.
        // token1 deposited is non-zero, proving an unbounded amount could pass through.
        assertGt(r[2], 0, "token1 should have been pulled via disabled slippage cap");
    }
}
