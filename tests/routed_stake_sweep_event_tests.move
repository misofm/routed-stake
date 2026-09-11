// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module routed_stake::routed_stake_sweep_event_tests;

use routed_stake::routed_stake::{Self};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::bcs;
use sui::event;

public struct A {}
public struct P {}
public struct U {}

fun setup(ctx: &mut TxContext): (UID, UID, RoyaltyPool<A, U>, RoyaltyPool<P, U>) {
    let mut a = object::new(ctx);
    let mut p = object::new(ctx);
    let sp = pool::new<A, U>(&mut a);
    let dp = pool::new<P, U>(&mut p);
    (a, p, sp, dp)
}

#[test]
fun deposited_sweep_event_asserts_all_fields() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut sp, mut dp) = setup(ctx);
    let pi = parent.to_inner(); let pa = pi.to_address();
    let mut r = routed_stake::new<A, P>(&mut parent, balance::create_for_testing<A>(1000), ctx);
    let ri = object::id(&r).to_address(); let si = object::id(r.stake()).to_address();
    r.register(&mut parent, &mut sp);
    let u = type_name::with_defining_ids<U>();
    sp.deposit(balance::create_for_testing<U>(500));
    let mut h = stake::new(balance::create_for_testing<P>(100), ctx);
    dp.register_stake(&mut h);
    let spi = object::id(&sp).to_address(); let dpi = object::id(&dp).to_address();
    let sb0 = sp.balance().value(); let ss = sp.staked_shares();
    let sx = sp.cumulative_reward_per_share(); let sc = sp.carry(); let sd = sp.cumulative_deposits();
    let db0 = dp.balance().value(); let ds = dp.staked_shares(); let dx0 = dp.cumulative_reward_per_share();
    let dc0 = dp.carry(); let dd0 = dp.cumulative_deposits(); let eb = stake::registration_debt(r.stake().get_registration(&u));
    assert_eq!(r.sweep(&mut sp, &mut dp, pi), 500);
    let ea = stake::registration_debt(r.stake().get_registration(&u));
    let sb1 = sp.balance().value(); let db1 = dp.balance().value(); let dx1 = dp.cumulative_reward_per_share();
    let dc1 = dp.carry(); let dd1 = dp.cumulative_deposits();
    let ev = event::events_by_type<routed_stake::RoutedStakeSweptEvent<A, P, U>>();
    assert_eq!(ev.length(), 1);
    let (a, b, c, d, e, f, g, h0, i, j, k, l, m, n, o, p0, q, r0, s0, t0, u0, v0, w0, x0, y0) = routed_stake::swept_event_fields(&ev[0]);
    assert_eq!(a, ri); assert_eq!(b, pa); assert_eq!(c, si); assert_eq!(d, spi); assert_eq!(e, dpi);
    assert_eq!(f, 500); assert_eq!(g, false); assert_eq!(h0, 1000); assert_eq!(i, sb0); assert_eq!(j, sb1);
    assert_eq!(k, ss); assert_eq!(l, sx); assert_eq!(m, sc); assert_eq!(n, sd); assert_eq!(o, eb); assert_eq!(p0, ea);
    assert_eq!(q, db0); assert_eq!(r0, db1); assert_eq!(s0, ds); assert_eq!(t0, dx0); assert_eq!(u0, dx1);
    assert_eq!(v0, dc0); assert_eq!(w0, dc1); assert_eq!(x0, dd0); assert_eq!(y0, dd1);
    assert!(ea > eb); assert!(sx > 0); assert_eq!(bcs::to_bytes(&ev[0]).length(), 481);
    destroy(h); destroy(r); destroy(sp); destroy(dp); asset.delete(); parent.delete();
}
