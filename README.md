# AetherZone Protocol Security Registry

This repository holds the official, cryptographically verified smart contract security audits, code integrity logs, and verification certificates for the **AetherZone Protocol** ecosystem.

## 🛡️ Verified Security Audits

| Document | Description | IPFS Decentralized Link |
| :--- | :--- | :--- |
| **[Smart Contract Security Audit](audits/smart_contract_audit.md)** | Deep security analysis of all core swap routing, zapping, and limit order contracts. | 🌐 **[IPFS Gateway Link](https://ipfs.io/ipfs/bafkreiamsfbcoqkzk4ectinmoow2dygshsjjjru3jlovpfdd6bwfmztmom)** |
| **[Cryptographic Audit Certificate](audits/audit_certificate.md)** | Verified sign-off containing exact compilation hashes of the live Mainnet contracts. | 🌐 **[IPFS Gateway Link](https://ipfs.io/ipfs/bafkreihwaomojzovz6dhyukq3rhj5amo3bdmkrg4x3ucwautwatnco5giu)** |


---

## 🏛️ Decentralized Governance & Timelock Verification

To guarantee maximum user safety and eliminate single-point-of-failure administration, the AetherZone Protocol has placed all core smart contracts under the control of an on-chain Timelock.

* **AetherTimelock Address:** [`0x332676075AB568a056b1CC178E9C84252A986a5D`](https://shidoscan.net/address/0x332676075AB568a056b1CC178E9C84252A986a5D#code)
* **Delay Parameter:** **48 Hours** (Mandatory delay enforced on all structural updates)
* **Emergency Operations:** Whitelisted instant pause capability for swift crisis response.

### Deployed & Locked Contracts
The following core contracts have transferred their full ownership to the `AetherTimelock` contract:
1. **`AetherGuard`:** [`0xE77B8B211e2c95f125C0d3b2Aa17d56c74fa3660`](https://shidoscan.net/address/0xE77B8B211e2c95f125C0d3b2Aa17d56c74fa3660)
2. **`RetailLimitOrders`:** [`0xF8048aBd73B2aBE02114A31e6F68B6C66bA98B18`](https://shidoscan.net/address/0xF8048aBd73B2aBE02114A31e6F68B6C66bA98B18)
3. **`AetherOTCEscrow`:** [`0xDc812945b24E27BA5DBe17C71329a355Cd575239`](https://shidoscan.net/address/0xDc812945b24E27BA5DBe17C71329a355Cd575239)
4. **`AetherRevenueDistributorV2`:** [`0xCC532A532857ad5CC0A1d6726062Acc75554344D`](https://shidoscan.net/address/0xCC532A532857ad5CC0A1d6726062Acc75554344D)
5. **`AetherZap`:** [`0xB19f08512Eb6d256f85EcBe929e31baafB2c83DF`](https://shidoscan.net/address/0xB19f08512Eb6d256f85EcBe929e31baafB2c83DF)

---

## 🔒 Intellectual Property & Proprietary Warning

**All Rights Reserved.**

* The smart contracts, architecture, logic, and associated ecosystem code of the AetherZone Protocol are **proprietary and strictly protected by copyright**.
* **Forking, copying, replicating, distributing, or modifying** this codebase for personal, commercial, or external deployment without express written permission from the copyright owners is strictly prohibited.
* This repository serves strictly as a **Security Verification Registry** to provide full transparency to users, depositors, and auditors regarding on-chain contract integrity.

---

*Certified by the Lead Security Architect, Antigravity Security Labs.*
