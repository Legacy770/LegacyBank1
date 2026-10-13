# LegacyBank

An onchain bank for stablecoin savers. Users **lock** (not stake) stablecoins for a chosen duration, between 4 months and 3 years. Leaving early is possible but costs a 10% penalty, which is there to encourage real savings behavior. Deposits earn **points** (1 point per stablecoin) that can be redeemed in future partner campaigns. Admins can allocate part of the pooled funds to **Aave** to generate protocol yield.

> **Status:** unaudited. Do not deploy to mainnet with real funds before a professional audit.

---

## Contents

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Smart contracts](#smart-contracts)
- [Points backend](#points-backend)
- [Local development](#local-development)
- [Deployment](#deployment)
- [Security notes](#security-notes)

---

## How it works

```
 User ──deposit(token, amount, duration)──▶ LegacyBank ──0.5% fee──▶ Treasury
                                               │
                                               ├─ locks the remaining 99.5% until unlock time
                                               ├─ operators may supply part of the pool to Aave
                                               └─ emits Deposited / Withdrawn / EmergencyWithdrawn
                                                          │
                                                          ▼
                                                 Indexer (backend)
                                                          │
                                                          ▼
                                              Points ledger + REST API
```

| Rule | Value |
| --- | --- |
| Minimum lock | 120 days (about 4 months) |
| Maximum lock | 1095 days (3 years) |
| Deposit fee | 0.5% of the amount received, sent to the treasury |
| Early withdrawal penalty | 10% of the locked amount, sent to the treasury |
| Points | 1:1 with the locked stablecoin amount, normalized by token decimals |
| Aave allocation | Operator-controlled, capped at a percentage of user liabilities |

**Example:** a user deposits 1,000 USDC. 5 USDC goes to the treasury as the fee and 995 USDC is locked. At maturity they withdraw 995 USDC. If they exit early they receive 895.5 USDC and 99.5 USDC goes to the treasury.

---

## Repository layout

The contracts and backend are separate projects. A simple monorepo layout looks like this:

```
legacybank/
├── contracts/                  # Foundry project
│   ├── foundry.toml
│   ├── src/
│   │   ├── LegacyBank.sol
│   │   └── interfaces/IAavePool.sol
│   ├── test/
│   │   ├── LegacyBank.t.sol
│   │   └── mocks/Mocks.sol
│   └── script/Deploy.s.sol
└── backend/                    # TypeScript indexer + API
    ├── package.json
    ├── .env.example
    └── src/
        ├── config.ts
        ├── db.ts
        ├── indexer.ts
        ├── api.ts
        └── index.ts
```

---

## Smart contracts

Built with Solidity 0.8.24, Foundry, and OpenZeppelin v5.

### User functions

| Function | Description |
| --- | --- |
| `deposit(token, amount, duration)` | Locks funds for `duration` seconds. Takes the 0.5% fee, records a position, and returns its id. Reverts for unsupported tokens or durations outside 120 days to 1095 days. |
| `withdraw(id)` | Returns the full locked amount after the unlock time. |
| `emergencyWithdraw(id)` | Exits before the unlock time. Returns 90% to the user and sends 10% to the treasury. |

Each deposit is its own position, so a user can hold many positions with different durations. Use `getUserPositions(user)` to list them.

### Operator and admin functions

| Function | Access | Description |
| --- | --- | --- |
| `allocateToAave(token, amount)` | operator | Supplies idle funds to Aave, capped at `maxAllocationBps` of `totalLocked`. |
| `deallocateFromAave(token, amount)` | operator | Pulls principal back from Aave. |
| `harvestYield(token)` | operator | Sends accrued Aave yield (aToken balance above tracked principal) to the treasury. |
| `configureToken(token, supported, aToken)` | owner | Whitelists or disables a stablecoin and sets its Aave aToken. |
| `setOperator(addr, enabled)` | owner | Grants or revokes operator rights. |
| `setTreasury(addr)` | owner | Changes the fee and penalty recipient. |
| `setMaxAllocationBps(bps)` | owner | Changes the Aave allocation cap (maximum 10000). |
| `pause()` / `unpause()` | owner | Blocks or allows new deposits. |

### Design guarantees

- **Withdrawals are never blocked.** Pausing and disabling a token only stop new deposits.
- **Auto-pull from Aave.** If idle balance is too low to pay a withdrawal, the contract withdraws the shortfall from Aave automatically.
- **Allocation cap.** Only part of user liabilities can sit in Aave, which keeps a liquidity buffer.
- **Fee-on-transfer safe.** Deposits are measured by actual balance received.
- **Two-step ownership transfer** via `Ownable2Step`.

### Events (consumed by the backend)

```solidity
event Deposited(uint256 indexed id, address indexed user, address indexed token,
                uint256 grossAmount, uint256 fee, uint256 lockedAmount,
                uint256 lockDuration, uint256 unlockTime);
event Withdrawn(uint256 indexed id, address indexed user, address indexed token, uint256 amount);
event EmergencyWithdrawn(uint256 indexed id, address indexed user, address indexed token,
                         uint256 returned, uint256 penalty);
```

---

## Points backend

A TypeScript service (viem, SQLite, Fastify) that indexes contract events and maintains a points ledger.

- **Indexer:** polls `getLogs` in chunks, only reading blocks that are `CONFIRMATIONS` deep so reorgs are not a concern.
- **Exactly-once accounting:** each chunk's writes and the cursor update share one database transaction, and every ledger entry has a unique `ref` (`txHash:logIndex`).
- **Append-only ledger:** a balance is the sum of ledger deltas. Deposits add points, early exits add a `revoke` entry (configurable), and redemptions add a negative `redeem` entry.
- **Precision:** points are stored as integer micro-points (6 decimals, 1 point = 1,000,000), so no floating point is involved.

### Configuration

Copy `.env.example` to `.env`:

| Variable | Description | Default |
| --- | --- | --- |
| `RPC_URL` | JSON-RPC endpoint of the chain | required |
| `BANK_ADDRESS` | Deployed LegacyBank address | required |
| `START_BLOCK` | Block the contract was deployed at | `0` |
| `CONFIRMATIONS` | Blocks to wait before indexing | `12` |
| `CHUNK_SIZE` | Blocks per `getLogs` request | `2000` |
| `POLL_MS` | Polling interval in milliseconds | `10000` |
| `REVOKE_ON_EMERGENCY` | Remove a position's points when it exits early | `true` |
| `ADMIN_KEY` | Secret for admin endpoints | required |
| `PORT` | API port | `3000` |
| `DB_PATH` | SQLite file path | `./legacybank.db` |

### REST API

| Method | Endpoint | Description |
| --- | --- | --- |
| GET | `/points/:address` | Current points balance |
| GET | `/positions/:address` | The user's positions and their status (`active`, `withdrawn`, `emergency`) |
| GET | `/history/:address` | Ledger history for the user |
| GET | `/leaderboard?limit=50` | Top point holders |
| POST | `/admin/redeem` | Spend points for a campaign (requires `x-admin-key` header) |

Redeem example:

```bash
curl -X POST http://localhost:3000/admin/redeem \
  -H 'x-admin-key: <ADMIN_KEY>' -H 'content-type: application/json' \
  -d '{"address":"0x...","points":"250","campaign":"partner-x-airdrop","ref":"partner-x-0001"}'
```

Redemptions are idempotent on `ref`, so retrying the same request never double-spends.

---

## Local development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 20 or newer

### Contracts

```bash
cd contracts
forge install OpenZeppelin/openzeppelin-contracts
forge build
forge test -vv
```

`foundry.toml` needs the remapping `@openzeppelin/=lib/openzeppelin-contracts/` and `solc = "0.8.24"`.

The test suite uses a mock USDC, mock aToken, and mock Aave pool. It covers fees, duration bounds, withdrawal timing, the early-exit penalty, double-withdraw protection, the allocation cap, auto-pull from Aave, yield harvesting, access control, and pausing.

### Backend against a local chain

```bash
# Terminal 1: local chain
anvil

# Terminal 2: deploy the contracts (set the env vars described below first)
cd contracts
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 \
  --private-key <anvil-key> --broadcast

# Terminal 3: backend
cd backend
npm install
cp .env.example .env     # set RPC_URL=http://127.0.0.1:8545, BANK_ADDRESS, CONFIRMATIONS=0
npm run dev
```

Then make a deposit with `cast send` and check `GET /points/<address>`.

---

## Deployment

The deploy script reads these environment variables:

| Variable | Description |
| --- | --- |
| `AAVE_POOL` | Aave V3 Pool address for the target chain |
| `TREASURY` | Fee and penalty recipient (use a multisig) |
| `USDC` | Stablecoin address |
| `AUSDC` | The matching Aave aToken address |

```bash
cd contracts
forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

Look up the Aave Pool and aToken addresses for your chain in the official Aave documentation. After deploying:

1. Set the deployed address and its deployment block in the backend `.env`.
2. Transfer ownership to a multisig (the transfer is two-step, so the new owner must accept it).
3. Add operator addresses for the team members who will manage Aave allocation.

---

## Security notes

- **Get an audit** before real funds are involved.
- **Use a multisig** for the owner and the treasury. The owner controls token configuration, the treasury address, operators, and pausing.
- **Aave risk.** Funds supplied to Aave are exposed to protocol risk and to withdrawal liquidity limits. Keep the allocation cap conservative.
- **Stablecoin risk.** Only whitelist stablecoins you have reviewed. A depegged or blacklisting token (such as a centralized stablecoin that can freeze addresses) affects the pool.
- **Points are wallet-based.** Splitting funds across wallets is possible, so consider eligibility rules in campaigns.
- **Backend admin key.** Keep `ADMIN_KEY` secret, put the API behind HTTPS, and restrict `/admin/*` routes to your own network if possible.

---

## License

MIT