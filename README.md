# Aegis Protocol

**Aegis** is a treasury-backed reserve protocol on Polygon, architected as a modular,
upgrade-safe system of onchain primitives. Inspired by the [OlympusDAO](https://www.olympusdao.finance/)
reserve-currency model, Aegis extends it with a native **membership graph**, a
**SpiderWeb** energy-distribution layer, and a curated **bond & staking** stack — all
composed into a single, governable foundation for protocol-owned liquidity.

---

## ✦ Highlights

- **Protocol-Owned Liquidity** — a self-sustaining treasury (`AegisTreasury`) that backs
  every unit of `ATH` with reserve assets.
- **Rebasing Staking** — `sATH`, a rebasing wrapper of `ATH` ported from the Olympus V1
  `sOlympusERC20`, drives auto-compounding yield across a versioned staking stack
  (`AegisStaking` → `V5`, plus `AegisLongStake`).
- **Bonding** — `AegisBondDepository` issues discounted `ATH` in exchange for reserve
  assets, deepening the treasury over time.
- **SpiderWeb Engine** — an energy-accumulation and distribution mesh
  (`EnergyAccumulator`, `Turbine`, `Turbocharger`, `SpiderWebDistributor`, `BurnHandler`)
  that routes protocol rewards through the membership network.
- **Membership Graph** — `MembershipV1` maintains an onchain referral tree with a
  TORCH-runner role for referrer assignment.
- **Initial Liquidity Offering** — `ILOV1` bootstraps the protocol's launch liquidity.
- **Governance & Identity** — `GATH` governance token and `SenatorNFT` for privileged
  participation.
- **Upgrade-Safe by Design** — every core contract is built on OpenZeppelin's
  upgradeable proxy pattern for safe, governed evolution.

---

## ✦ Architecture

```ml
contracts/
├─ ATH.sol              — "Core protocol reserve token"
├─ GATH.sol             — "Governance token"
├─ sATH.sol (staking/)  — "Rebasing staked ATH"
├─ MembershipV1.sol     — "Onchain referral / membership graph"
├─ ILOV1.sol            — "Initial Liquidity Offering"
├─ SenatorNFT.sol       — "Privileged-participant identity NFT"
├─ AdminAggregatorV1.sol— "Aggregated admin surface"
├─ Proxies.sol          — "Upgradeable proxy wiring"
│
├─ bond/        — "Bond depository & bond types"
├─ staking/     — "Versioned staking, distributors, long-stake, sATH"
├─ treasury/    — "Protocol-owned reserve treasury"
├─ oracle/      — "Manual & on-chain price oracles"
├─ spiderweb/   — "Energy accumulation & reward distribution mesh"
├─ interfaces/  — "Standard protocol interfaces"
└─ test/        — "Mocks, harnesses & test utilities"
