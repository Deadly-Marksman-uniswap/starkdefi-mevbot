use array::ArrayTrait;
use option::OptionTrait;
use core::traits::Into;
use starknet::account::Call;
use starknet::ContractAddress;
use starknet::get_caller_address;
use starknet::contract_address_const;

use starkDefi::dex::v1::pair::StarkDPair;
use starkDefi::dex::v1::pair::StarkDPair::StarkDPairImpl;
use starkDefi::dex::v1::pair::StarkDPair::InternalFunctions;
use starkDefi::dex::v1::pair::StarkDPair::Mint;
use starkDefi::dex::v1::pair::StarkDPair::Burn;
use starkDefi::dex::v1::pair::StarkDPair::Swap;
use starkDefi::dex::v1::pair::StarkDPair::Sync;

use starkDefi::dex::v1::pair::interface::IStarkDPair;
use starkDefi::dex::v1::pair::IStarkDPairDispatcher;
use starkDefi::dex::v1::pair::IStarkDPairDispatcherTrait;

use starkDefi::dex::v1::factory::StarkDFactory;
use starkDefi::dex::v1::factory::StarkDFactory::StarkDFactoryImpl;
use starkDefi::dex::v1::factory::interface::IStarkDFactoryDispatcher;
use starkDefi::dex::v1::factory::interface::IStarkDFactoryDispatcherTrait;

use starkDefi::token::erc20::ERC20;
use starkDefi::token::erc20::selectors;
use starkDefi::token::erc20::ERC20::ERC20Impl;
use starkDefi::token::erc20::ERC20::Transfer;
use starkDefi::token::erc20::interface::ERC20ABIDispatcherTrait;


use starkDefi::tests::helper_account::Account;
use starkDefi::tests::helper_account::AccountABIDispatcher;
use starkDefi::tests::helper_account::interface::AccountABIDispatcherTrait;


use starkDefi::tests::factory::factory_setup;
use starkDefi::tests::factory::deploy_factory;

use starkDefi::tests::utils::constants;
use starkDefi::tests::utils::functions::{drop_event, pop_log, setup_erc20, deploy};
use starkDefi::tests::utils::{deploy_erc20, token_at};
use starkDefi::tests::utils::account::setup_account;
use starknet::testing;
use debug::PrintTrait;

//
// Setup
//

fn deploy_pair() -> (IStarkDPairDispatcher, AccountABIDispatcher) {
    let account = setup_account();
    let factory = deploy_factory(account.contract_address);
    let token0 = deploy_erc20('Token0', 'TK0', 10000, account.contract_address);
    let token1 = deploy_erc20('Token1', 'TK1', 10000, account.contract_address);

    let pair = factory.create_pair(token0.contract_address, token1.contract_address);

    (IStarkDPairDispatcher { contract_address: pair }, account)
}


fn STATE() -> StarkDPair::ContractState {
    StarkDPair::contract_state_for_testing()
}

fn setup() -> StarkDPair::ContractState {
    let mut state = STATE();

    testing::set_caller_address(constants::FACTORY());
    testing::set_contract_address(constants::PAIR());
    StarkDPair::constructor(ref state, constants::TOKEN_0(), constants::TOKEN_1());
    drop_event(constants::ADDRESS_ZERO());

    state
}

//
// constructor
//

#[test]
#[available_gas(2000000)]
fn test_constructor() {
    let mut state = STATE();
    testing::set_caller_address(constants::CALLER());
    StarkDPair::constructor(ref state, constants::ADDRESS_ONE(), constants::ADDRESS_TWO());

    assert(StarkDPairImpl::token0(@state) == constants::ADDRESS_ONE(), 'Token0 eq ADDRESS_ONE');
    assert(StarkDPairImpl::token1(@state) == constants::ADDRESS_TWO(), 'Token1 eq ADDRESS_TWO');
    assert(StarkDPairImpl::factory(@state) == get_caller_address(), 'Factory eq caller address');

    // Starkd-p token
    assert(StarkDPairImpl::name(@state) == 'StarkDefi Pair', 'Name eq StarkDefi Pair');
    assert(StarkDPairImpl::symbol(@state) == 'STARKD-P', 'Symbol eq STARKD-P');
    assert(StarkDPairImpl::decimals(@state) == 18, 'Decimals eq 18');
    assert(StarkDPairImpl::total_supply(@state) == 0, 'Total supply eq 0');
}


//
// deployed pair
//

#[test]
#[available_gas(4000000)]
fn test_deployed_pair() {
    let (pairDispatcher, accountDispatcher) = deploy_pair();

    assert(pairDispatcher.token0() == constants::ADDRESS_THREE(), 'Token0 eq ADDRESS_THREE');
    assert(pairDispatcher.token1() == constants::ADDRESS_FOUR(), 'Token1 eq ADDRESS_FOUR');
    assert(pairDispatcher.factory() == constants::ADDRESS_TWO(), 'Factory eq ADDRESS_TWO');

    // tokens
    let token0Dispatcher = token_at(pairDispatcher.token0());
    let token1Dispatcher = token_at(pairDispatcher.token1());

    assert(token0Dispatcher.name() == 'Token0', 'Token0 name eq Token0');
    assert(token0Dispatcher.symbol() == 'TK0', 'Token0 symbol eq TK0');
    assert(token0Dispatcher.decimals() == 18, 'Token0 decimals eq 18');
    assert(token0Dispatcher.total_supply() == 10000, 'Token0 total supply eq 10000');
    assert(
        token0Dispatcher.balance_of(accountDispatcher.contract_address) == 10000,
        'Token0 balance eq 10000'
    );

    assert(token1Dispatcher.name() == 'Token1', 'Token1 name eq Token1');
    assert(token1Dispatcher.symbol() == 'TK1', 'Token1 symbol eq TK1');
    assert(token1Dispatcher.decimals() == 18, 'Token1 decimals eq 18');
    assert(token1Dispatcher.total_supply() == 10000, 'Token1 total supply eq 10000');
    assert(
        token1Dispatcher.balance_of(accountDispatcher.contract_address) == 10000,
        'Token1 balance eq 10000'
    );

    // Starkd-p token
    assert(pairDispatcher.name() == 'StarkDefi Pair', 'Name eq StarkDefi Pair');
    assert(pairDispatcher.symbol() == 'STARKD-P', 'Symbol eq STARKD-P');
    assert(pairDispatcher.decimals() == 18, 'Decimals eq 18');
    assert(pairDispatcher.total_supply() == 0, 'Total supply eq 0');
}

//
// mint
//

fn transfer_erc20(token: ContractAddress, to: ContractAddress, amount: u256) -> Call {
    let mut call = array![];
    Serde::serialize(@to, ref call);
    Serde::serialize(@amount, ref call);
    Call { to: token, selector: selectors::transfer, calldata: call }
}

fn add_initial_liquidity(
    token0_amount: u256, token1_amount: u256, feeOn: bool
) -> (IStarkDPairDispatcher, AccountABIDispatcher) {
    let (pairDispatcher, accountDispatcher) = deploy_pair();
    let token0Dispatcher = token_at(pairDispatcher.token0());
    let token1Dispatcher = token_at(pairDispatcher.token1());

    let mut calls = array![];

    // token0 transfer call
    calls
        .append(
            transfer_erc20(
                token0Dispatcher.contract_address, pairDispatcher.contract_address, token0_amount
            )
        );

    // token1 transfer call
    calls
        .append(
            transfer_erc20(
                token1Dispatcher.contract_address, pairDispatcher.contract_address, token1_amount
            )
        );

    // turn on fee
    if feeOn {
        let mut fee_calldata = array![];
        Serde::serialize(@constants::FEE_TO(), ref fee_calldata);
        calls
            .append(
                Call {
                    to: pairDispatcher.factory(),
                    selector: selectors::set_fee_to,
                    calldata: fee_calldata
                }
            );
    }

    // mint lp
    let mut mint_calldata = array![];
    Serde::serialize(@accountDispatcher.contract_address, ref mint_calldata);

    calls
        .append(
            Call {
                to: pairDispatcher.contract_address,
                selector: selectors::mint,
                calldata: mint_calldata
            }
        );
    // multicall
    accountDispatcher.__execute__(calls);

    (pairDispatcher, accountDispatcher)
}

fn add_more_liquidity(
    ref pairDispatcher: IStarkDPairDispatcher,
    ref accountDispatcher: AccountABIDispatcher,
    token0_amount: u256,
    token1_amount: u256
) {
    let token0Dispatcher = token_at(pairDispatcher.token0());
    let token1Dispatcher = token_at(pairDispatcher.token1());

    let mut calls = array![];

    // token0 transfer call
    calls
        .append(
            transfer_erc20(
                token0Dispatcher.contract_address, pairDispatcher.contract_address, token0_amount
            )
        );

    // token1 transfer call
    calls
        .append(
            transfer_erc20(
                token1Dispatcher.contract_address, pairDispatcher.contract_address, token1_amount
            )
        );

    // mint lp
    let mut mint_calldata = array![];
    Serde::serialize(@accountDispatcher.contract_address, ref mint_calldata);

    calls
        .append(
            Call {
                to: pairDispatcher.contract_address,
                selector: selectors::mint,
                calldata: mint_calldata
            }
        );
    // multicall
    accountDispatcher.__execute__(calls);
}

#[test]
#[available_gas(20000000)]
fn test_mint() {
    let (pairDispatcher, accountDispatcher) = deploy_pair();

    let token0Dispatcher = token_at(pairDispatcher.token0());
    let token1Dispatcher = token_at(pairDispatcher.token1());

    assert(pairDispatcher.total_supply() == 0, 'Total supply eq 0');
    assert(pairDispatcher.balance_of(accountDispatcher.contract_address) == 0, 'Balance eq 0');

    // multicall transfer to pair
    let mut calls = array![];

    // token0 transfer call
    let call0 = transfer_erc20(
        token0Dispatcher.contract_address, pairDispatcher.contract_address, 5000
    );

    // token1 transfer call
    let call1 = transfer_erc20(
        token1Dispatcher.contract_address, pairDispatcher.contract_address, 3000
    );

    calls.append(call0);
    calls.append(call1);

    // multicall
    accountDispatcher.__execute__(calls);
    assert(
        token0Dispatcher.balance_of(pairDispatcher.contract_address) == 5000,
        'Token0 balance eq 5000'
    );
    assert(
        token1Dispatcher.balance_of(pairDispatcher.contract_address) == 3000,
        'Token1 balance eq 3000'
    );

    // mint
    pairDispatcher.mint(accountDispatcher.contract_address);
    // sqrt (5000 * 3000) = 3872
    assert(pairDispatcher.total_supply() == 3872, 'Total supply eq 3872');
    assert(
        pairDispatcher.balance_of(accountDispatcher.contract_address) == 2872, 'Balance eq 3872'
    );
    assert(
        pairDispatcher.balance_of(contract_address_const::<'deAd'>()) == 1000, 'Balance eq 1000'
    );

    let (r1, r2, _) = pairDispatcher.get_reserves();
    assert(r1 == 5000, 'Reserve 1 eq 5000');
    assert(r2 == 3000, 'Reserve 2 eq 3000');
}

#[test]
#[available_gas(20000000)]
#[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED'))]
fn test_mint_no_zero_tokens() {
    let (pairDispatcher, accountDispatcher) = deploy_pair();
    // mint
    pairDispatcher.mint(accountDispatcher.contract_address);
}

#[test]
#[available_gas(20000000)]
#[should_panic(
    expected: ('insufficient liquidity minted', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
)]
fn test_ming_not_enough_tokens() {
    let (pairDispatcher, accountDispatcher) = add_initial_liquidity(1000, 1000, false);
}

//
// swap
//

fn swap(
    ref pairDispatcher: IStarkDPairDispatcher,
    ref accountDispatcher: AccountABIDispatcher,
    amountToSwap: u256,
    amount0Out: u256,
    amount1Out: u256
) {
    let token0Dispatcher = token_at(pairDispatcher.token0());
    let token1Dispatcher = token_at(pairDispatcher.token1());

    let mut calls = array![];

    // transfer token to be swapped
    let token_to_be_swapped = if amount0Out == 0 {
        token0Dispatcher.contract_address
    } else {
        token1Dispatcher.contract_address
    };

    calls
        .append(transfer_erc20(token_to_be_swapped, pairDispatcher.contract_address, amountToSwap));

    // swap
    let data: Array::<felt252> = array![];

    let mut swap_calldata = array![];
    Serde::serialize(@amount0Out, ref swap_calldata);
    Serde::serialize(@amount1Out, ref swap_calldata);
    Serde::serialize(@accountDispatcher.contract_address, ref swap_calldata);
    Serde::serialize(@data, ref swap_calldata);
    calls
        .append(
            Call {
                to: pairDispatcher.contract_address,
                selector: selectors::swap,
                calldata: swap_calldata
            }
        );

    // multicall
    accountDispatcher.__execute__(calls);
}

#[test]
#[available_gas(10000000)]
fn test_swap_token0_for_token1() {
    let (mut pairDispatcher, mut accountDispatcher) = add_initial_liquidity(5000, 3000, false);
    let token0Dispatcher = token_at(pairDispatcher.token0());
    let token1Dispatcher = token_at(pairDispatcher.token1());

    // swap
    swap(ref pairDispatcher, ref accountDispatcher, 30, 0, 17);
    let (res0, res, _) = pairDispatcher.get_reserves();

    assert(res0 == 5030, 'Reserve 1 eq 5030');
    assert(res == 2983, 'Reserve 2 eq 2983');
    assert(
        token0Dispatcher.balance_of(pairDispatcher.contract_address) == 5030,
        'Token0 balance eq 5030'
    );
    assert(
        token1Dispatcher.balance_of(pairDispatcher.contract_address) == 2983,
        'Token1 balance eq 2983'
    );
    assert(
        token0Dispatcher.balance_of(accountDispatcher.contract_address) == 4970,
        'Token0 balance eq 4970'
    );
    assert(
        token1Dispatcher.balance_of(accountDispatcher.contract_address) == 7017,
        'Token1 balance eq 7017'
    )
}
