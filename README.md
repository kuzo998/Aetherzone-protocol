# AetherZone Protocol: Smart Contracts & Security Registry

Official open-source smart contract repository and security verification registry for the **AetherZone Protocol** on the **Shido Network**.

---

## 🛡️ Verified Security Audits

| Document | Description | Scope |
| :--- | :--- | :--- |
| **[Smart Contract Security Audit](audits/smart_contract_audit.md)** | Full security review of core trading, order routing, OTC escrow, and revenue contracts. | Core Protocol v2.1 |
| **[Staking & Marketplace Audit](audits/staking_and_marketplace_audit.md)** | Security analysis of StakePoolFactory, LP incentives, and reserve escrow rails. | Staking & Marketplace |
| **[Cryptographic Audit Certificate](audits/audit_certificate.md)** | Cryptographic verification certificate and bytecode match attestation. | All Production Contracts |

---

## 📋 Deployed & Verified Contracts Directory

All contracts are deployed on the **Shido Network** and 100% verified on [Shidoscan](https://shidoscan.net):

### 1. Staking & Yield Rails
* **StakePoolFactory**: [`0x59eE0da93DE70A6bE9C597089Cc01A2a2f499085`](https://shidoscan.net/address/0x59eE0da93DE70A6bE9C597089Cc01A2a2f499085)
* **AetherStakePool (Master Impl)**: [`0x34299BFcDB8da2EF8779Fb54a4d8d4716a3e77d3`](https://shidoscan.net/address/0x34299BFcDB8da2EF8779Fb54a4d8d4716a3e77d3)
* **AetherLPGauge**: [`0xECbd5f2dfe7033f2c62E2FfB668b600d96946E20`](https://shidoscan.net/address/0xECbd5f2dfe7033f2c62E2FfB668b600d96946E20)
* **AetherReserveEscrow (Active)**: [`0x4AE8907e183DEfD989adF86529491627DE714B0e`](https://shidoscan.net/address/0x4AE8907e183DEfD989adF86529491627DE714B0e)

### 2. Trading & Liquidity Rails
* **AetherZap Router**: [`0xB19f08512Eb6d256f85EcBe929e31baafB2c83DF`](https://shidoscan.net/address/0xB19f08512Eb6d256f85EcBe929e31baafB2c83DF)
* **AetherRangeManager**: [`0x3c8558ed0C67e06469Cf76d88D48a036C2ABac69`](https://shidoscan.net/address/0x3c8558ed0C67e06469Cf76d88D48a036C2ABac69)
* **AetherOrderRouter**: [`0x268b498AD7F4102C643d39A70C636934f4d00975`](https://shidoscan.net/address/0x268b498AD7F4102C643d39A70C636934f4d00975)
* **RetailLimitOrders**: [`0xF8048aBd73B2aBE02114A31e6F68B6C66bA98B18`](https://shidoscan.net/address/0xF8048aBd73B2aBE02114A31e6F68B6C66bA98B18)
* **WhaleLimitOrders**: [`0xca2838F3a7b94Acc158b2D8Bc15e30B277f5111e`](https://shidoscan.net/address/0xca2838F3a7b94Acc158b2D8Bc15e30B277f5111e)

### 3. Marketplace & P2P Escrow
* **AetherOTC Escrow**: [`0xDc812945b24E27BA5DBe17C71329a355Cd575239`](https://shidoscan.net/address/0xDc812945b24E27BA5DBe17C71329a355Cd575239)
* **AetherFund Pool**: [`0xfdF721b2b44dA4e112c8daE16B320D47E63955a8`](https://shidoscan.net/address/0xfdF721b2b44dA4e112c8daE16B320D47E63955a8)

### 4. Security & Governance
* **RevenueDistributor V2**: [`0xCC532A532857ad5CC0A1d6726062Acc75554344D`](https://shidoscan.net/address/0xCC532A532857ad5CC0A1d6726062Acc75554344D)
* **AetherGuard**: [`0xE77B8B211e2c95f125C0d3b2Aa17d56c74fa3660`](https://shidoscan.net/address/0xE77B8B211e2c95f125C0d3b2Aa17d56c74fa3660)
* **AetherMulticall2**: [`0xe3da1EC9e9BfEa1fE8C5905133c36A86351e4561`](https://shidoscan.net/address/0xe3da1EC9e9BfEa1fE8C5905133c36A86351e4561)
* **AetherTimelock**: [`0x332676075AB568a056b1CC178E9C84252A986a5D`](https://shidoscan.net/address/0x332676075AB568a056b1CC178E9C84252A986a5D)

---

## 🚀 Verification Submitter

Source code can be verified on Shidoscan using the automated verification tool:

```bash
# Dry run verification payload test
node verification/verify-submit.js --dry-run

# Submit live verification
node verification/verify-submit.js
```
