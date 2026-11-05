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

All contracts are deployed on the **Shido Network** (Chain ID: `9008`) and 100% verified on [Shidoscan](https://shidoscan.net):

### 1. Staking & Yield Rails
* **StakePoolFactory (v7 - Active)**: [`0x386bfd9d4f2BC9BCBA56194E776510917570C01C`](https://shidoscan.net/address/0x386bfd9d4f2BC9BCBA56194E776510917570C01C)
* **AetherStakePool (Master Impl v7)**: [`0x772553d6c62d3794853Ba229b0030fADAe2403a7`](https://shidoscan.net/address/0x772553d6c62d3794853Ba229b0030fADAe2403a7)
* **StakePoolFactory (Legacy v6)**: [`0x59eE0da93DE70A6bE9C597089Cc01A2a2f499085`](https://shidoscan.net/address/0x59eE0da93DE70A6bE9C597089Cc01A2a2f499085)
* **AetherStakePool (Master Impl v6)**: [`0x34299BFcDB8da2EF8779Fb54a4d8d4716a3e77d3`](https://shidoscan.net/address/0x34299BFcDB8da2EF8779Fb54a4d8d4716a3e77d3)
* **AetherLPGauge**: [`0xECbd5f2dfe7033f2c62E2FfB668b600d96946E20`](https://shidoscan.net/address/0xECbd5f2dfe7033f2c62E2FfB668b600d96946E20)
* **AetherReserveEscrow (Active)**: [`0x4432D41b0720Cb329BfFe99Efb1ec8F36464D24B`](https://shidoscan.net/address/0x4432D41b0720Cb329BfFe99Efb1ec8F36464D24B)

### 2. Trading & Liquidity Rails
* **AetherZap Router**: [`0xa3cdAb065960A34679b5A85dE108834B82fcC785`](https://shidoscan.net/address/0xa3cdAb065960A34679b5A85dE108834B82fcC785)
* **AetherRangeManager**: [`0x3c8558ed0C67e06469Cf76d88D48a036C2ABac69`](https://shidoscan.net/address/0x3c8558ed0C67e06469Cf76d88D48a036C2ABac69)
* **AetherOrderRouter**: [`0x268b498AD7F4102C643d39A70C636934f4d00975`](https://shidoscan.net/address/0x268b498AD7F4102C643d39A70C636934f4d00975)
* **RetailLimitOrders**: [`0xF8048aBd73B2aBE02114A31e6F68B6C66bA98B18`](https://shidoscan.net/address/0xF8048aBd73B2aBE02114A31e6F68B6C66bA98B18)
* **WhaleLimitOrders**: [`0xB7708613B53f9d3c62Fd23197816D2043ba200c0`](https://shidoscan.net/address/0xB7708613B53f9d3c62Fd23197816D2043ba200c0)

### 3. Marketplace, P2P Escrow & Community Vaults
* **AetherOTC Escrow V2 (Active)**: [`0x770aDed9Af4C1c74850AF659de63407637ebf640`](https://shidoscan.net/address/0x770aDed9Af4C1c74850AF659de63407637ebf640)
* **AetherFundPool V2 (Hardened)**: [`0x07fa59d440ae45770C912DD9764f41108CC0FE7f`](https://shidoscan.net/address/0x07fa59d440ae45770C912DD9764f41108CC0FE7f)
* **AetherMerkleDistributor**: [`contracts/AetherMerkleDistributor.sol`](contracts/AetherMerkleDistributor.sol)
* **AetherMessengerHub**: [`contracts/AetherMessengerHub.sol`](contracts/AetherMessengerHub.sol)
* **AetherPayGateway**: [`contracts/AetherPayGateway.sol`](contracts/AetherPayGateway.sol)
* **AetherDojoRaffle**: [`contracts/AetherDojoRaffle.sol`](contracts/AetherDojoRaffle.sol)

### 4. Security & Governance
* **RevenueDistributor V2**: [`0xb86528DB0Cc3d1304F3bF0c360D5F04fcAd5C8E3`](https://shidoscan.net/address/0xb86528DB0Cc3d1304F3bF0c360D5F04fcAd5C8E3)
* **AetherGuard**: [`0x78f748d82554581D9cBC93D5A465eeBEECD1716b`](https://shidoscan.net/address/0x78f748d82554581D9cBC93D5A465eeBEECD1716b)
* **AetherMulticall**: [`0x21A751e4c24FB1cbbff191D9fF8287b19c5f266d`](https://shidoscan.net/address/0x21A751e4c24FB1cbbff191D9fF8287b19c5f266d)
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
