use array::{ArrayTrait, SpanTrait};
use starknet::{ContractAddress};
use starknet::testing;
use pragma::entry::structs::{Currency, Pair, PossibleEntries, SpotEntry, BaseEntry};
use pragma::randomness::example_randomness::{
    ExampleRandomness, IExampleRandomnessDispatcher, IExampleRandomnessDispatcherTrait
};
use pragma::randomness::randomness::{
    Randomness, IRandomnessDispatcher, IRandomnessDispatcherTrait, RequestStatus
};
use openzeppelin::token::erc20::{ERC20, interface::{IERC20Dispatcher, IERC20DispatcherTrait}};
use pragma::publisher_registry::publisher_registry::{
    IPublisherRegistryABIDispatcher, IPublisherRegistryABIDispatcherTrait, PublisherRegistry
};
use pragma::oracle::oracle::{IOracleABIDispatcher, IOracleABIDispatcherTrait, Oracle};
use starknet::contract_address::contract_address_const;
use starknet::syscalls::deploy_syscall;
use option::OptionTrait;
use starknet::SyscallResultTrait;
use serde::Serde;
use result::ResultTrait;
use traits::{Into, TryInto};
use starknet::info;
const INITIAL_SUPPLY: u128 = 100000000000000000000000000;
const CHAIN_ID: felt252 = 'SN_MAIN';
const BLOCK_TIMESTAMP: u64 = 103374042;
const MAX_PREMIUM_FEE: u128 = 100000000; // 1$ with 8 decimals
const ETH_USD_PRICE: u128 = 2000000;

fn pop_log<T, impl TDrop: Drop<T>, impl TEvent: starknet::Event<T>>(
    address: ContractAddress
) -> Option<T> {
    let (mut keys, mut data) = testing::pop_log_raw(address)?;
    let ret = starknet::Event::deserialize(ref keys, ref data);
    assert(data.is_empty(), 'Event has extra data');
    ret
}


fn setup() -> (
    IRandomnessDispatcher,
    IExampleRandomnessDispatcher,
    ContractAddress,
    ContractAddress,
    IERC20Dispatcher
) {
    let admin_address = contract_address_const::<0x1234>();
    starknet::testing::set_contract_address(admin_address);
    starknet::testing::set_chain_id(CHAIN_ID);
    starknet::testing::set_block_timestamp(BLOCK_TIMESTAMP);
    // TOKEN 1 deployment
    let mut token_1_calldata = ArrayTrait::new();
    let token_1: felt252 = 'Pragma1';
    let symbol_1: felt252 = 'PRA1';
    let initial_supply: u256 = u256 { high: 0, low: INITIAL_SUPPLY };
    token_1.serialize(ref token_1_calldata);
    symbol_1.serialize(ref token_1_calldata);
    initial_supply.serialize(ref token_1_calldata);
    admin_address.serialize(ref token_1_calldata);
    let (token_1_address, _) = deploy_syscall(
        ERC20::TEST_CLASS_HASH.try_into().unwrap(), 0, token_1_calldata.span(), true
    )
        .unwrap_syscall();
    let mut token_1 = IERC20Dispatcher { contract_address: token_1_address };
    // PUBLISHER REGISTRY deployment
    let mut constructor_calldata = ArrayTrait::new();
    constructor_calldata.append(admin_address.into());
    let (publisher_registry_address, _) = deploy_syscall(
        PublisherRegistry::TEST_CLASS_HASH.try_into().unwrap(), 0, constructor_calldata.span(), true
    )
        .unwrap_syscall();
    let mut publisher_registry = IPublisherRegistryABIDispatcher {
        contract_address: publisher_registry_address
    };

    // ORACLE deployment
    let mut currencies = ArrayTrait::<Currency>::new();
    currencies
        .append(
            Currency {
                id: 'ETH',
                decimals: 8_u32,
                is_abstract_currency: false, // True (1) if not a specific token but abstract, e.g. USD or ETH as a whole
                starknet_address: 0
                    .try_into()
                    .unwrap(), // optional, e.g. can have synthetics for non-bridged assets
                ethereum_address: 0.try_into().unwrap(), // optional
            }
        );

    currencies
        .append(
            Currency {
                id: 'USD',
                decimals: 8_u32,
                is_abstract_currency: false, // True (1) if not a specific token but abstract, e.g. USD or ETH as a whole
                starknet_address: 0
                    .try_into()
                    .unwrap(), // optional, e.g. can have synthetics for non-bridged assets
                ethereum_address: 0.try_into().unwrap(), // optional
            }
        );
    let mut pairs = array![
        Pair { id: 'ETH/USD', base_currency_id: 'ETH', quote_currency_id: 'USD', }
    ];

    let mut oracle_calldata = ArrayTrait::new();
    admin_address.serialize(ref oracle_calldata);
    publisher_registry_address.serialize(ref oracle_calldata);
    currencies.serialize(ref oracle_calldata);
    pairs.serialize(ref oracle_calldata);
    let (oracle_address, _) = deploy_syscall(
        Oracle::TEST_CLASS_HASH.try_into().unwrap(), 0, oracle_calldata.span(), true
    )
        .unwrap_syscall();

    let mut oracle = IOracleABIDispatcher { contract_address: oracle_address };

    // Data publish
    let now = 100000;
    publisher_registry.add_publisher(1, admin_address);
    // Add source 1 for publisher 1
    publisher_registry.add_source_for_publisher(1, 1);
    // Add source 2 for publisher 1
    publisher_registry.add_source_for_publisher(1, 2);
    oracle
        .publish_data(
            PossibleEntries::Spot(
                SpotEntry {
                    base: BaseEntry { timestamp: now, source: 1, publisher: 1 },
                    pair_id: 'ETH/USD',
                    price: ETH_USD_PRICE,
                    volume: 12131
                }
            )
        );
    // RANDOMNESS deployment
    let public_key = 12345678;
    let mut calldata = ArrayTrait::new();
    admin_address.serialize(ref calldata);
    public_key.serialize(ref calldata);
    token_1_address.serialize(ref calldata);
    oracle_address.serialize(ref calldata);
    let (randomness_contract, _) = deploy_syscall(
        Randomness::TEST_CLASS_HASH.try_into().unwrap(), 0, calldata.span(), true
    )
        .unwrap_syscall();
    let randomness_dispatcher = IRandomnessDispatcher { contract_address: randomness_contract };
    let mut example_calldata = ArrayTrait::new();
    randomness_contract.serialize(ref example_calldata);
    let (example_randomness_contract, _) = deploy_syscall(
        ExampleRandomness::TEST_CLASS_HASH.try_into().unwrap(), 0, example_calldata.span(), true
    )
        .unwrap_syscall();
    let example_randomness_dispatcher = IExampleRandomnessDispatcher {
        contract_address: example_randomness_contract
    };
    token_1.transfer(example_randomness_contract, u256 { high: 0, low: INITIAL_SUPPLY / 20 });
    token_1.balance_of(example_randomness_contract);
    assert(
        token_1
            .balance_of(example_randomness_contract) == u256 { high: 0, low: INITIAL_SUPPLY / 20 },
        'wrong initial balance'
    );
    starknet::testing::set_contract_address(example_randomness_contract);
    token_1.approve(randomness_contract, u256 { high: 0, low: INITIAL_SUPPLY });

    return (
        randomness_dispatcher,
        example_randomness_dispatcher,
        randomness_contract,
        example_randomness_contract,
        token_1
    );
}

// ============================================================================
// PoC — Permanent freezing of `callback_fee` funds in
//                   `Randomness.submit_random` (broken fee accounting)
// ----------------------------------------------------------------------------
// At request time the user deposits `wei_premium_fee + callback_fee_limit`.
// At fulfilment `submit_random`:
//   * refunds the *unused* budget `callback_fee_limit - callback_fee` to the
//     callback, and
//   * credits ONLY `total_fees - callback_fee_limit == wei_premium_fee` to
//     `admin_fees`.
// The consumed `callback_fee` is therefore left in the contract's ERC-20
// balance with NO accounting entry, and `withdraw_funds` can only move
// `admin_fees`. Because the request is now FULFILLED, every other money path
// (`cancel_random_request`, `refund_operation`, `update_status`) is blocked.
// Net result: `callback_fee` worth of tokens is permanently frozen per
// fulfilled request.
//
// Concrete numbers used below (see `setup`):
//   premium_fee       = (MAX_PREMIUM_FEE * 1e18) / ETH_USD_PRICE = 5e19
//   callback_fee_limit= 900_000_000
//   callback_fee      = 1_000_000
//   -> physical contract balance after fulfilment = premium_fee + callback_fee
//   -> admin_fees credited                        = premium_fee
//   -> stuck (unrecoverable)                      = callback_fee = 1_000_000
// ============================================================================

// Drives one full request -> fulfil -> withdraw lifecycle and returns the
// contract's residual ERC-20 balance together with its `admin_fees` accounting
// after the admin has withdrawn everything it *can* withdraw.
fn run_full_lifecycle_and_drain() -> (u256, u256, u256) {
    let admin = contract_address_const::<0x1234>();
    let (randomness, example_randomness, randomness_address, example_randomness_address, token_1) =
        setup();

    let premium_fee = (MAX_PREMIUM_FEE * 1000000000000000000) / ETH_USD_PRICE; // 5e19
    let seed = 1;
    let callback_fee_limit = 900000000;
    let callback_fee = 1000000;
    let callback_address = example_randomness_address;
    let publish_delay = 1;
    let num_words = 1;
    let calldata = array!['Pragma1', 'PRA1', 'INITIAL_SUPPLY', '0x1234'];

    // --- user requests randomness: deposits premium_fee + callback_fee_limit ---
    testing::set_contract_address(example_randomness_address);
    randomness
        .request_random(
            seed, callback_address, callback_fee_limit, publish_delay, num_words, calldata.clone()
        );

    let balance_after_request = token_1.balance_of(randomness_address);
    assert(
        balance_after_request == premium_fee.into() + callback_fee_limit.into(),
        'deposit accounting wrong'
    );

    // --- operator (admin) fulfils the request ---
    let random_words = array![10000];
    let proof = array![100, 200, 300];
    testing::set_block_number(4);
    testing::set_contract_address(admin);
    randomness
        .submit_random(
            0,
            example_randomness_address,
            seed,
            1,
            callback_address,
            callback_fee_limit,
            callback_fee,
            random_words.span(),
            proof.span(),
            calldata
        );

    // Physically the contract still holds premium_fee + callback_fee,
    // but it only *accounts* for premium_fee in `admin_fees`.
    let balance_after_fulfil = token_1.balance_of(randomness_address);
    assert(
        balance_after_fulfil == premium_fee.into() + callback_fee.into(),
        'physical balance wrong'
    );
    assert(randomness.get_contract_balance() == premium_fee.into(), 'admin_fees != premium_fee');

    // --- admin withdraws everything it is *able* to withdraw (only admin_fees) ---
    randomness.withdraw_funds(admin);

    let residual_balance = token_1.balance_of(randomness_address);
    let accounted = randomness.get_contract_balance(); // admin_fees, now 0
    (residual_balance, accounted, callback_fee.into())
}

// MAIN PoC: after the admin drains all funds it can, `callback_fee` worth of
// tokens is still sitting in the contract while the accounting says it is empty.
#[test]
#[available_gas(100000000000)]
fn test_poc_callback_fee_permanently_frozen() {
    let (residual_balance, accounted, callback_fee) = run_full_lifecycle_and_drain();

    // Accounting believes the contract is empty...
    assert(accounted == 0.into(), 'admin_fees should be 0');
    // ...yet `callback_fee` worth of the payment token is physically stuck.
    assert(residual_balance == callback_fee, 'stuck != callback_fee');
    assert(residual_balance > 0.into(), 'funds should be frozen');
}

// No-recovery proof #1: `withdraw_funds` cannot reach the stuck tokens. On the
// *same* contract that still physically holds `callback_fee`, a withdrawal with
// `admin_fees == 0` reverts — `withdraw_funds` only ever references `admin_fees`,
// never the residual ERC-20 balance.
#[test]
#[should_panic(expected: ('insufficient contract balance', 'ENTRYPOINT_FAILED'))]
#[available_gas(100000000000)]
fn test_poc_no_recovery_withdraw_reverts_when_drained() {
    let admin = contract_address_const::<0x1234>();
    let (randomness, example_randomness, randomness_address, example_randomness_address, token_1) =
        setup();
    let premium_fee = (MAX_PREMIUM_FEE * 1000000000000000000) / ETH_USD_PRICE;
    let seed = 1;
    let callback_fee_limit = 900000000;
    let callback_fee = 1000000;
    let callback_address = example_randomness_address;
    let publish_delay = 1;
    let num_words = 1;
    let calldata = array!['Pragma1', 'PRA1', 'INITIAL_SUPPLY', '0x1234'];

    testing::set_contract_address(example_randomness_address);
    randomness
        .request_random(
            seed, callback_address, callback_fee_limit, publish_delay, num_words, calldata.clone()
        );

    let random_words = array![10000];
    let proof = array![100, 200, 300];
    testing::set_block_number(4);
    testing::set_contract_address(admin);
    randomness
        .submit_random(
            0,
            example_randomness_address,
            seed,
            1,
            callback_address,
            callback_fee_limit,
            callback_fee,
            random_words.span(),
            proof.span(),
            calldata
        );

    // First withdrawal succeeds and drains `admin_fees` (== premium_fee).
    randomness.withdraw_funds(admin);

    // The contract still physically holds `callback_fee`...
    assert(
        token_1.balance_of(randomness_address) == callback_fee.into(), 'precondition: funds frozen'
    );
    // ...but admin_fees is 0, so this withdrawal reverts — the residual is unreachable.
    randomness.withdraw_funds(admin);
}

// No-recovery proof #2: a FULFILLED request can no longer be moved OUT_OF_GAS,
// so `refund_operation` (the only user-facing refund path) stays unreachable.
#[test]
#[should_panic(expected: ('request already fulfilled', 'ENTRYPOINT_FAILED'))]
#[available_gas(100000000000)]
fn test_poc_no_recovery_update_status_blocked_after_fulfilment() {
    let admin = contract_address_const::<0x1234>();
    let (randomness, example_randomness, randomness_address, example_randomness_address, token_1) =
        setup();
    let seed = 1;
    let callback_fee_limit = 900000000;
    let callback_fee = 1000000;
    let callback_address = example_randomness_address;
    let publish_delay = 1;
    let num_words = 1;
    let calldata = array!['Pragma1', 'PRA1', 'INITIAL_SUPPLY', '0x1234'];

    testing::set_contract_address(example_randomness_address);
    randomness
        .request_random(
            seed, callback_address, callback_fee_limit, publish_delay, num_words, calldata.clone()
        );

    let random_words = array![10000];
    let proof = array![100, 200, 300];
    testing::set_block_number(4);
    testing::set_contract_address(admin);
    randomness
        .submit_random(
            0,
            example_randomness_address,
            seed,
            1,
            callback_address,
            callback_fee_limit,
            callback_fee,
            random_words.span(),
            proof.span(),
            calldata
        );

    // FULFILLED cannot be moved to OUT_OF_GAS to unlock `refund_operation`.
    randomness.update_status(example_randomness_address, 0, RequestStatus::OUT_OF_GAS(()));
}

// No-recovery proof #3: calling `refund_operation` directly on the FULFILLED
// request reverts because its status is not OUT_OF_GAS — confirming the
// callback_fee cannot be refunded to the user either.
#[test]
#[should_panic(expected: ('request not out of gas', 'ENTRYPOINT_FAILED'))]
#[available_gas(100000000000)]
fn test_poc_no_recovery_refund_blocked_after_fulfilment() {
    let admin = contract_address_const::<0x1234>();
    let (randomness, example_randomness, randomness_address, example_randomness_address, token_1) =
        setup();
    let seed = 1;
    let callback_fee_limit = 900000000;
    let callback_fee = 1000000;
    let callback_address = example_randomness_address;
    let publish_delay = 1;
    let num_words = 1;
    let calldata = array!['Pragma1', 'PRA1', 'INITIAL_SUPPLY', '0x1234'];

    testing::set_contract_address(example_randomness_address);
    randomness
        .request_random(
            seed, callback_address, callback_fee_limit, publish_delay, num_words, calldata.clone()
        );

    let random_words = array![10000];
    let proof = array![100, 200, 300];
    testing::set_block_number(4);
    testing::set_contract_address(admin);
    randomness
        .submit_random(
            0,
            example_randomness_address,
            seed,
            1,
            callback_address,
            callback_fee_limit,
            callback_fee,
            random_words.span(),
            proof.span(),
            calldata
        );

    // Status is FULFILLED, not OUT_OF_GAS -> refund path is closed.
    testing::set_contract_address(example_randomness_address);
    randomness.refund_operation(example_randomness_address, 0);
}
