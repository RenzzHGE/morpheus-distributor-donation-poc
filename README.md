# Morpheus — DistributorV2 aToken-donation yield-share manipulation (PoC)

Foundry proof-of-concept for a bug bounty report submitted to the Morpheus
team (devs@mor.org) under the Morpheus Bug Bounty Program v2.

## The finding

`DistributorV2.distributeRewards()` measures a pool's "yield" as a live
balance delta (`aToken balance − lastUnderlyingBalance`). A direct transfer of
aTokens to the Distributor is indistinguishable from real Aave yield, so an
unprivileged attacker can inflate their pool's measured yield and steal a
share of the FIXED daily MOR emission from every other pool's stakers.

Target: `DistributorV2` implementation
`0x52f76e8be3dfabcc3b0ded02882a22be47dade03` behind proxy
`0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A`, function
`distributeRewards(uint256)`, with DepositPool USDT
`0x3B51989212BEdaB926794D6bf8e9E991218cf116`. Ethereum Mainnet.

## Measured result (mainnet fork, block 26420000, 15 days)

| | Control (no donation) | Attack (donation) | Delta |
|---|---|---|---|
| Attacker pending MOR | 1,606 | 19,838 | +18,232 MOR |
| Representative victim, 1000 stETH (1x) | 3,568 | 1,800 | −1,767 MOR |

- Total stolen from other stakers: 18,232 MOR × $0.6977 = **$12,720**
- Donation cost: 15 × $437 = **$6,555**
- Attacker net profit: **$6,165 over 15 days** (~$411/day), repeatable daily
- Profitable even at a $0.50/MOR floor ($9,116 gain > $6,555 cost)

## Run

```sh
forge test
```

Runs `test_donationStealsEmission` (differential control/attack proof, asserts
the loss) and `test_claimLeg` (claim after the 14-day lock). Defaults to the
public RPC `https://ethereum.publicnode.com`; override with
`MOR_RPC_URL=<archive RPC> forge test`.

No privileged accounts are used and no `vm.prank` of any protocol address
appears anywhere. The attacker and victim are fresh EOAs. The victim's stETH
comes from a real Lido deposit. Fork-simulation notes (Chainlink feed mocking
to real fork-block answers, Lido rebase at the measured 0.20 stETH/day) are
documented in the test file header; the donation effect itself is not mocked.

## Disclosure

Reported to devs@mor.org. Please do not disclose publicly until the issue is
fixed and Morpheus confirms disclosure is OK.
