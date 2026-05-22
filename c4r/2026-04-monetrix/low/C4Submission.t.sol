// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// In-scope tokens
import {USDM} from "../../src/tokens/USDM.sol";
import {sUSDM} from "../../src/tokens/sUSDM.sol";
import {sUSDMEscrow} from "../../src/tokens/sUSDMEscrow.sol";

// In-scope core
import {MonetrixVault} from "../../src/core/MonetrixVault.sol";
import {MonetrixAccountant} from "../../src/core/MonetrixAccountant.sol";
import {MonetrixConfig} from "../../src/core/MonetrixConfig.sol";
import {RedeemEscrow} from "../../src/core/RedeemEscrow.sol";
import {YieldEscrow} from "../../src/core/YieldEscrow.sol";
import {InsuranceFund} from "../../src/core/InsuranceFund.sol";

// In-scope governance
import {MonetrixAccessController} from "../../src/governance/MonetrixAccessController.sol";

// In-scope constants
import {HyperCoreConstants} from "../../src/interfaces/HyperCoreConstants.sol";

// Shared test mocks
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockCoreDepositWallet} from "../mocks/MockCoreDepositWallet.sol";

/// @dev No-op CoreWriter. Any `sendRawAction` call is accepted silently so PoCs
///      exercising Operator paths (hedge/bridge/HLP/BLP) don't revert at the
///      HyperCore boundary.
contract _PoCMockCoreWriter {
    event ActionSent(bytes action);

    function sendRawAction(bytes calldata action) external {
        emit ActionSent(action);
    }
}

/// @dev Controllable mock for every HyperCore read-precompile (0x0800..0x0811).
///      Defaults to 128 zero bytes so Accountant's fail-closed decoders treat
///      unmocked slots as "no position / zero balance". Override per-slot from
///      your PoC via `setResponse(key, value)`.
contract _PoCMockPrecompile {
    mapping(bytes32 => bytes) public responses;

    function setResponse(bytes calldata callData, bytes calldata response) external {
        responses[keccak256(callData)] = response;
    }

    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes memory r = responses[keccak256(data)];
        if (r.length == 0) return new bytes(128);
        return r;
    }
}

/// @title  C4Submission — PoC template for Code4rena wardens
/// @notice Every High/Medium submission must be demonstrated inside
///         `test_submissionValidity`. `setUp()` deploys the full Monetrix
///         protocol (all in-scope contracts behind ERC-1967 UUPS proxies),
///         wires roles, mocks HyperCore precompiles + CoreWriter, and funds
///         two test users with 1M USDC each.
///
///         How to submit:
///           1. **Do not copy this file.** Edit it in place.
///           2. Write your exploit inside the body of `test_submissionValidity`.
///              Use the provided helpers (`_deposit`, `_stake`, `_requestRedeem`,
///              `_mockVaultL1SpotUsdc`, `_mockVaultL1SuppliedUsdc`).
///           3. Leave `setUp()` alone unless your finding genuinely requires
///              different initial state. If you must change it, restrict the
///              edits to the minimum needed and document why in a comment.
///           4. Run `forge test --match-path "test/c4/C4Submission.t.sol" -vvv`
///              and confirm `test_submissionValidity` passes (i.e. your PoC
///              terminates in the expected faulty state).
contract C4Submission is Test {
    // ─── In-scope contracts ─────────────────────────────────────
    MonetrixAccessController public acl;
    USDM public usdm;
    sUSDM public susdm;
    sUSDMEscrow public unstakeEscrow;
    InsuranceFund public insurance;
    MonetrixConfig public config;
    MonetrixVault public vault;
    MonetrixAccountant public accountant;
    RedeemEscrow public redeemEscrow;
    YieldEscrow public yieldEscrow;

    // ─── Test doubles ───────────────────────────────────────────
    MockUSDC public usdc;
    MockCoreDepositWallet public depositWallet;

    // ─── Actors ─────────────────────────────────────────────────
    /// @dev `admin` is DEFAULT_ADMIN + GOVERNOR + GUARDIAN + UPGRADER so every
    ///      privileged setter can be reached via `vm.prank(admin)`.
    address public admin = address(0xAD);
    address public operator = address(0xBB);
    address public foundation = address(0xF0);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public virtual {
        // ── Mocks (USDC + CoreDepositWallet) ──────────────────
        usdc = new MockUSDC();
        depositWallet = new MockCoreDepositWallet(address(usdc));

        vm.startPrank(admin);

        // ── ACL (bootstrap: admin is the sole DEFAULT_ADMIN) ──
        acl = MonetrixAccessController(
            address(
                new ERC1967Proxy(
                    address(new MonetrixAccessController()),
                    abi.encodeCall(MonetrixAccessController.initialize, (admin))
                )
            )
        );

        // ── USDM ──────────────────────────────────────────────
        usdm = USDM(
            address(new ERC1967Proxy(address(new USDM()), abi.encodeCall(USDM.initialize, (address(acl)))))
        );

        // ── InsuranceFund (USDC-denominated, holds reserves) ──
        insurance = InsuranceFund(
            address(
                new ERC1967Proxy(
                    address(new InsuranceFund()),
                    abi.encodeCall(InsuranceFund.initialize, (address(usdc), address(acl)))
                )
            )
        );

        // ── Config (parameters + insurance/foundation routing) ──
        config = MonetrixConfig(
            address(
                new ERC1967Proxy(
                    address(new MonetrixConfig()),
                    abi.encodeCall(MonetrixConfig.initialize, (address(insurance), foundation, address(acl)))
                )
            )
        );

        // ── sUSDM (ERC-4626 staking wrapper over USDM) ────────
        susdm = sUSDM(
            address(
                new ERC1967Proxy(
                    address(new sUSDM()),
                    abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
                )
            )
        );

        // ── Vault (user deposit/redeem entrypoint) ────────────
        vault = MonetrixVault(
            address(
                new ERC1967Proxy(
                    address(new MonetrixVault()),
                    abi.encodeCall(
                        MonetrixVault.initialize,
                        (
                            address(usdc),
                            address(usdm),
                            address(susdm),
                            address(config),
                            address(depositWallet),
                            address(acl)
                        )
                    )
                )
            )
        );

        // ── Accountant (backing / settle / yield gates) ───────
        accountant = MonetrixAccountant(
            address(
                new ERC1967Proxy(
                    address(new MonetrixAccountant()),
                    abi.encodeCall(
                        MonetrixAccountant.initialize,
                        (address(vault), address(usdc), address(usdm), address(acl))
                    )
                )
            )
        );

        // ── RedeemEscrow (custody of pending redemption USDC) ─
        redeemEscrow = RedeemEscrow(
            address(
                new ERC1967Proxy(
                    address(new RedeemEscrow()),
                    abi.encodeCall(RedeemEscrow.initialize, (address(usdc), address(vault), address(acl)))
                )
            )
        );

        // ── YieldEscrow (custody of declared yield USDC) ──────
        yieldEscrow = YieldEscrow(
            address(
                new ERC1967Proxy(
                    address(new YieldEscrow()),
                    abi.encodeCall(YieldEscrow.initialize, (address(usdc), address(vault), address(acl)))
                )
            )
        );

        // ── Roles. admin plays Governor/Guardian/Upgrader; operator is distinct. ──
        acl.grantRole(acl.GOVERNOR(), admin);
        acl.grantRole(acl.GUARDIAN(), admin);
        acl.grantRole(acl.OPERATOR(), admin);
        acl.grantRole(acl.OPERATOR(), operator);
        acl.grantRole(acl.UPGRADER(), admin);

        // ── Bind USDM/sUSDM mint/burn authority to the vault ──
        usdm.setVault(address(vault));
        susdm.setVault(address(vault));

        // ── sUSDMEscrow (non-upgradeable custody for the unstake queue) ──
        unstakeEscrow = new sUSDMEscrow(address(usdm), address(susdm));
        susdm.setEscrow(address(unstakeEscrow));

        // ── Wire vault → escrows + accountant, accountant → config ──
        vault.setAccountant(address(accountant));
        vault.setRedeemEscrow(address(redeemEscrow));
        vault.setYieldEscrow(address(yieldEscrow));
        accountant.setConfig(address(config));

        // ── Open Gate 1 of the settle pipeline ────────────────
        accountant.initializeSettlement();

        vm.stopPrank();

        // ── Etch HyperCore precompiles (read paths) ──────────
        //    Every slot the Accountant reads through PrecompileReader is backed
        //    by a fresh _PoCMockPrecompile. Default response is 128 zero bytes.
        //    Override from your PoC via `_MOCK_PRECOMPILE(...).setResponse(...)`.
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_ORACLE_PX, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_PERP_ASSET_INFO, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_TOKEN_INFO, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_POSITION, address(new _PoCMockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SPOT_PX, address(new _PoCMockPrecompile()).code);

        // ── Etch CoreWriter (write path) ──────────────────────
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new _PoCMockCoreWriter()).code);

        // ── Fund users with 1M USDC each ─────────────────────
        usdc.mint(user1, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════
    //  Helpers — use inside your PoC to reduce boilerplate.
    // ═══════════════════════════════════════════════════════════

    /// @dev USDC → USDM (1:1 mint via vault.deposit).
    function _deposit(address user, uint256 usdcAmount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), usdcAmount);
        vault.deposit(usdcAmount);
        vm.stopPrank();
    }

    /// @dev USDM → sUSDM (ERC-4626 stake).
    function _stake(address user, uint256 usdmAmount) internal {
        vm.startPrank(user);
        usdm.approve(address(susdm), usdmAmount);
        susdm.deposit(usdmAmount, user);
        vm.stopPrank();
    }

    /// @dev Queue a redemption request. Returns the request id for later claim.
    function _requestRedeem(address user, uint256 usdmAmount) internal returns (uint256 requestId) {
        vm.startPrank(user);
        usdm.approve(address(vault), usdmAmount);
        requestId = vault.requestRedeem(usdmAmount);
        vm.stopPrank();
    }

    /// @dev Seed the vault's L1 spot USDC balance on the mock 0x801 precompile.
    ///      `l1Amount8dp` is in 8-decimal HL wei (USDC on L1 is 8-dp internally).
    function _mockVaultL1SpotUsdc(uint64 l1Amount8dp) internal {
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(l1Amount8dp, uint64(0), uint64(0))
        );
    }

    /// @dev Seed the vault's L1 supplied (Portfolio Margin) USDC balance on 0x811.
    ///      Layout: `(uint64, uint64, uint64, uint64 supplied)` — reader takes
    ///      the 4th slot.
    function _mockVaultL1SuppliedUsdc(uint64 l1Amount8dp) internal {
        _PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(0), uint64(0), uint64(0), l1Amount8dp)
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  YOUR POC GOES HERE.
    //
    //  Do not rename `test_submissionValidity`, do not create a new
    //  test file, and do not modify anything outside this function
    //  body unless `setUp()` genuinely cannot produce the precondition
    //  you need. The judge runs this exact test name to verify your
    //  submission.
    //
    //  The body below is a placeholder that only exercises the default
    //  scaffolding so the test passes out of the box. Replace it with
    //  the steps that trigger your finding; the test should still pass
    //  at the end, with assertions proving the bug.
    // ═══════════════════════════════════════════════════════════

    function test_submissionValidity() public {
        // ─── Placeholder — replace with your PoC ───
        emit log_named_uint("usdm.decimals", usdm.decimals());
        emit log_named_uint("susdm.decimals", susdm.decimals());

        assertEq(susdm.decimals(), 12);
    }
}
