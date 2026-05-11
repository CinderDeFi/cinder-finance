# Cinder — Launch Package

Auto-compound sFLR and stXRP yield on Flare Network.
Built by one person. Open source. Unaudited — $50K TVL cap.

---

## QUICK START

### 1. Deploy frontend (30 seconds)
1. Go to https://netlify.com → sign up free
2. Drag the entire `frontend/` folder onto the Netlify dashboard
3. Live URL appears immediately
4. (Optional) Add custom domain in Site settings → Domain management

### 2. Deploy contracts (testnet first)
```bash
cd contracts/
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox ethers dotenv

# Create hardhat.config.js (see below)
# Create .env with your PRIVATE_KEY

# Testnet first
npx hardhat run ../scripts/deploy-solo.js --network coston2

# After testing — mainnet
npx hardhat run ../scripts/deploy-solo.js --network flare
```

hardhat.config.js:
```js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();
module.exports = {
  solidity: "0.8.20",
  networks: {
    flare:   { url: "https://flare-api.flare.network/ext/C/rpc",   accounts: [process.env.PRIVATE_KEY] },
    coston2: { url: "https://coston2-api.flare.network/ext/C/rpc", accounts: [process.env.PRIVATE_KEY] },
  }
};
```

.env:
```
PRIVATE_KEY=your_wallet_private_key_here
EMBER_ADDRESS=                    # set after deploy — CinderToken contract
STXRP_ADDRESS=                    # leave blank until Firelight launches
EMBER_FLR_PAIR=                   # set after running add-liquidity.js
```

### 3. After deploy — update frontend
Paste your deployed addresses into the CONTRACTS object in `frontend/index.html`:
```js
const CONTRACTS = {
  14: {
    zap: "0xYOUR_ZAP_ADDRESS",
    vaults: [
      { asset:"0x12e605bc104e93B45e1aD99F9e555f659051c2BB",
        vault:"0xYOUR_SFLR_VAULT", ... },
    ]
  }
}
```
Same for `ADDRS` in `frontend/governance.html`.
Re-drag the folder to Netlify to redeploy.

### 4. Activate (on Flarescan)
- `CinderMining.startMining()` 
- `CinderSale.startSale()`
- `CinderToken.delegate(yourAddress)` — self-delegate to vote

### 5. Gelato automation
- Go to https://app.gelato.network
- Create Resolver task → your GelatoResolver address → `checker()`
- Fund with ~20 FLR for gas

### 6. Sparkdex liquidity
```bash
# Set EMBER_ADDRESS and PRIVATE_KEY in .env
node scripts/add-liquidity.js
# Get pair address from Flarescan output
# Set EMBER_FLR_PAIR= in .env
# Re-run deploy-solo.js step 11 for LP vaults
```

---

## FILE STRUCTURE

```
frontend/
  index.html          ← Main app (drag to Netlify)
  governance.html     ← Governance + tokenomics
  about.html          ← About + risk disclosure
  netlify.toml        ← Deployment config (auto CSP, routing, cache)

contracts/
  CinderVault.sol      ← sFLR + stXRP staking vaults
  CinderZap.sol        ← One-click FLR → sFLR → cFLR
  CinderLPVault.sol    ← Sparkdex LP token vaults
  CinderLPZap.sol      ← One-click FLR → LP → cLP
  CinderToken.sol           ← EMBER governance token (1B fixed supply)
  CinderMining.sol          ← Liquidity mining (450M EMBER over 4 years)
  CinderGovernor.sol        ← On-chain governance (Compound Bravo)
  CinderTimelock.sol        ← Treasury (no multisig, governance only)
  CinderFounderVest.sol     ← 100M EMBER, 2yr linear, no cliff
  CinderSale.sol            ← 150M EMBER public sale, 10 EMBER/FLR
  CinderGelatoResolver.sol  ← Automated harvest trigger

scripts/
  deploy-solo.js      ← Full 11-step deploy (all contracts)
  add-liquidity.js    ← Seed Sparkdex EMBER/FLR pool (~$2K)

marketing/
  x-launch-thread.md    ← 12-tweet launch thread
  discord-posts.md      ← Pre-launch + launch day Discord posts
  sceptre-outreach.md   ← Outreach to Sceptre team
  week1-updates.md      ← 7 daily update templates
  onepager.html         ← Non-technical landing page
```

---

## KEY ADDRESSES (Flare Mainnet)

| Contract | Address |
|----------|---------|
| sFLR (Sceptre) | `0x12e605bc104e93B45e1aD99F9e555f659051c2BB` |
| Sceptre Pool | `0xb53Da25e918F9Df67f8dEDFeC83d7e81F3a0D0d` |
| Sparkdex Router | `0x16b619B04c961b8Ce3A0E3FB8572dB3E55b99dB7` |
| Sparkdex Factory | `0x6040BB9E4E12B7e8dc5BcEbbE5b76b9E86dBd35E` |
| WFLR | `0x1D80c49BbBCd1C0911346656B529DF9E5c2F783d` |
| FTSO Registry | `0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019` |

---

## TOKENOMICS

| Allocation | Amount | Vesting |
|-----------|--------|---------|
| Mining rewards | 450M (45%) | 4 years via CinderMining |
| Treasury | 250M (25%) | Timelock — governance vote required |
| Public sale | 150M (15%) | 6-month linear post-TGE |
| Founder | 100M (10%) | 2yr linear, no cliff |
| Community/airdrop | 50M (5%) | 90-day claim window |

Sale price: 10 EMBER per FLR (~$0.001/EMBER at $0.01 FLR)
Liquidity: 1M EMBER + 100K FLR on Sparkdex (~$2K pool)

---

## SECURITY

- Unaudited — Code4rena audit planned post-launch
- $50,000 TVL hard cap until audit completes
- Raised by governance vote after clean audit
- Static analysis: run Slither + Mythril before mainnet
- Bug reports: security@cinder.finance

---

## LAUNCH CHECKLIST

[ ] Run Slither on all contracts: `slither contracts/`
[ ] Deploy to Coston2 testnet
[ ] Test all functions on Coston2 via Flarescan
[ ] Deploy to Flare mainnet
[ ] Call CinderMining.startMining()
[ ] Call CinderSale.startSale()
[ ] Self-delegate: CinderToken.delegate(yourAddress)
[ ] Register Gelato task
[ ] Run add-liquidity.js → seed Sparkdex pool
[ ] Update CONTRACTS in index.html + governance.html
[ ] Get WalletConnect Project ID → replace YOUR_PROJECT_ID
[ ] Drag frontend/ to Netlify
[ ] (Optional) Add custom domain
[ ] Post pre-launch Discord message
[ ] Message Sceptre team
[ ] Post X launch thread
[ ] Submit DeFiLlama PR after live TVL
[ ] Submit FIP-0 to raise governance quorum to 10%

---

Built on Flare Network · github.com/cinderfinance · security@cinder.finance
