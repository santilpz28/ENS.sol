<!-- README.md -->
<p align="center">
 
</p>

<h1 align="center">Simple ENS (v4)</h1>

<p align="center">
  <b>Ultra-light, fully-governed, Ethereum-native name service</b><br>
  <sub>1 file · 300 lines · gas–friendly · battle-tested patterns (OpenZeppelin)</sub>
</p>

<p align="center">
  <a href="https://github.com/foundry-rs/foundry"><img alt="Foundry" src="https://img.shields.io/badge/Built%20with-Foundry-blue?logo=ethereum"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/License-MIT-green.svg"></a>
  <img alt="Solidity version" src="https://img.shields.io/badge/Solidity-%5E0.8.20-white.svg?logo=ethereum">
</p>

---

## ✨  Why another ENS?

Most ENS clones are **huge or fragile**.  
**Simple ENS** distills the essential flows into one compact contract:

* **Register** a name (e.g. `alice.eth`) for **1 year** – fee configurable  
* **Renew** per month (0.0001 ETH default) with a **60-day grace**  
* **On-chain bids** – only best offer stored, previous bid auto-refunded  
* **Governable fees** – hand ownership to a Governor/Timelock ⛓️  
* **Security-first**: `Ownable`, `ReentrancyGuard`, pull-payments, name normalization  
* Zero external storage → **<50 k gas** for first registration

> Perfect for hackathons, tutorials or side-chains that need a lean name service.

---

## ⚙️  Install & build

```bash
# 1. Clone & install libs
git clone https://github.com/<YOU>/simple-ens.git && cd simple-ens
forge install OpenZeppelin/openzeppelin-contracts          # OZ
forge install foundry-rs/forge-std                         # tests / console

# 2. Compile
forge build

# 3. Run tests
forge test -vvvv
