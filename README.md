# PegHook Foundry Template

Deploy a Uniswap v4 **dynamic-fee hook** (“PegHook”), create a pool, add liquidity, and swap on **Arbitrum Sepolia** — all with Foundry scripts.

---

## ✨ What’s inside

Scripts (all paths relative to repo root):

- `script/00_DeployHook.s.sol` – Mines flags & deploys `PegHook` with `CREATE2`
- `script/01_CreatePoolAndAddLiquidityPegHook.s.sol` – Initializes pool **with the hook** and mints initial liquidity (1 tx flow via PositionManager)
- `script/02_AddLiquidity.s.sol` – Adds more liquidity to an existing pool/position
- `script/03_Swap.s.sol` – Executes a swap through the pool (dynamic fee applied by hook)

Hook requires **dynamic fees**; your pool’s `PoolKey.fee` must be **0x800000** (the `DYNAMIC_FEE_FLAG`) — not `flag | base`.

---

## 🔧 Prerequisites

- **Foundry** (forge/cast): <https://book.getfoundry.sh/>
- Node (optional, for any TS/viem tooling you use)
- RPC for **Arbitrum Sepolia**

---

## 🔑 Environment

Create a `.env` in the repo root:

```bash
# Network
ARBITRUM_SEPOLIA_RPC=https://sepolia-rollup.arbitrum.io/rpc

# Deployer key (choose one style)
# 1) Use CLI flag --private-key (recommended), or
# 2) Make available to scripts:
WALLET_SECRET=0xYOUR_PRIVATE_KEY

# Uniswap v4 addresses (Arbitrum Sepolia)
POOL_MANAGER=0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317
POSITION_MANAGER=0xAc631556d3d4019C95769033B5E719dD77124BAc
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
STATE_VIEW=0x9D467FA9062b6e9B1a46E26007aD82db116c67cB

# Tokens (example)
USDC=0x5eff990c0A24A5F384119808398d1A64cE4BC537   # 6 decimals
yBTC=0x65eDC65510AE691bb4F2BeD5283A004e4ebD8Ee3   # 18 decimals

# (Filled after deploy)
HOOK_ADDR=0x... # set by 00_DeployHook.s.sol output

# Optional: position introspection
TICK_LOWER=-887280
TICK_UPPER=887280
```

> If you don’t want the script to read `WALLET_SECRET`, pass `--private-key 0x...` on the CLI instead.

---

## ⚙️ Install & Build

```bash
forge install
forge build
```

---

## 1) 🚀 Deploy the PegHook

The hook address must encode specific **permission flags** in its `CREATE2` address. The script mines a salt and deploys.

```bash
forge script script/00_DeployHook.s.sol   --rpc-url $ARBITRUM_SEPOLIA_RPC   --broadcast   --private-key 0xYOUR_PRIVATE_KEY
```

Output will include the **hook address**. Put it into `.env` as `HOOK_ADDR`.

**Expected permissions** (example): `beforeInitialize=true`, `beforeSwap=true`, others false — matching your hook’s `getHookPermissions()`.

---

## 2) 🫧 Create Pool & Add Initial Liquidity (with PegHook)

This initializes the pool with `PoolKey` that includes your `HOOK_ADDR` and the **dynamic fee flag**:

> **Important:** `fee = 0x800000` (only the flag), not `0x800000 | 3000`.

```bash
forge script script/01_CreatePoolAndAddLiquidityPegHook.s.sol   --rpc-url $ARBITRUM_SEPOLIA_RPC   --broadcast   --private-key 0xYOUR_PRIVATE_KEY
```

This script:
- Sorts tokens into `currency0/currency1`
- Computes `sqrtPriceX96` for your desired start price
- Calls `PositionManager.initializePool` and `modifyLiquidities` to mint your first position

---

## 3) ➕ Add More Liquidity

```bash
forge script script/02_AddLiquidity.s.sol   --rpc-url $ARBITRUM_SEPOLIA_RPC   --broadcast   --private-key 0xYOUR_PRIVATE_KEY
```

Configure the desired range / amounts inside the script (or via env), then mint more liquidity to the same pool.

---

## 4) 🔁 Swap

```bash
forge script script/03_Swap.s.sol   --rpc-url $ARBITRUM_SEPOLIA_RPC   --broadcast   --private-key 0xYOUR_PRIVATE_KEY
```

Your hook will set the **dynamic LP fee** in `beforeSwap` (it must return `fee | OVERRIDE_FEE_FLAG`).

---

## 🔎 Inspecting Pool State

There are no “reserves” per-pool in v4; assets live in a shared **PoolManager vault**. Pool “size” is represented by **active liquidity**, ticks, and positions.

### Quick checks with `cast`

```bash
# slot0: sqrtPriceX96, tick, protocolFee, lpFee
cast call $STATE_VIEW   "getSlot0((address,address,uint24,int24,address))((uint160,int24,uint24,uint24))"   "($USDC,$yBTC,0x800000,60,$HOOK_ADDR)"   --rpc-url $ARBITRUM_SEPOLIA_RPC

# total active liquidity at current tick
cast call $STATE_VIEW   "getLiquidity((address,address,uint24,int24,address))(uint128)"   "($USDC,$yBTC,0x800000,60,$HOOK_ADDR)"   --rpc-url $ARBITRUM_SEPOLIA_RPC
```

> Expect `lpFee=0` until a swap occurs — the dynamic fee is applied on-the-fly at swap time by your hook.

### Reading your position’s token amounts

For one range \[tickLower, tickUpper] with current price inside the range:

- `amount0 = (L * (sqrtUpper - sqrtP) * Q96) / (sqrtUpper * sqrtP)`
- `amount1 = (L * (sqrtP - sqrtLower)) / Q96`  
  where `Q96 = 2^96` and all sqrt prices are Q64.96.

Use your **position’s liquidity** `L` (from your mint), *not* the pool aggregate, if you want *your* amounts.

---

## 🧠 Dynamic Fee Notes

- **PoolKey.fee** must be `0x800000` (**only** the dynamic flag).  
  Adding a base pips (e.g., `| 3000`) can cause `LPFeeTooLarge`.
- Your hook must revert on static-fee pools (e.g., `MustUseDynamicFee()`), and override the fee on swap (`fee | OVERRIDE_FEE_FLAG`).

---

## 🧪 Common gotchas & fixes

- **`MustUseDynamicFee()` on initialize** – you used `fee=3000`. Set `fee=0x800000`.
- **`LPFeeTooLarge`** – you used `0x800000 | 3000`. Use **only** `0x800000`.
- **“No wallets found” (Foundry)** – pass `--private-key 0x...`, or ensure the script loads your key correctly.
- **`execution reverted` on `modifyLiquidities`** – check approvals, `amountMax`, tick bounds snapped to `tickSpacing`, and that the **PoolKey** (fee/spacing/hooks/token order) matches the initialized pool.
- **Address checksum errors (viem)** – normalize with `getAddress()` and ensure no hidden characters.

---

## 🗺️ Addresses (Arbitrum Sepolia)

- **PoolManager**: `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317`  
- **PositionManager**: `0xAc631556d3d4019C95769033B5E719dD77124BAc`  
- **StateView**: `0x9D467FA9062b6e9B1a46E26007aD82db116c67cB`  
- **Permit2**: `0x000000000022D473030F116dDEE9F6B43aC78BA3`

(If these change, update your `.env`.)

---

## 📂 Project layout

```
src/
  PegHook.sol           # your dynamic-fee hook
  ...
script/
  00_DeployHook.s.sol
  01_CreatePoolAndAddLiquidityPegHook.s.sol
  02_AddLiquidity.s.sol
  03_Swap.s.sol
```

---

## ✅ Checklist

- [ ] Set RPC + keys in `.env`
- [ ] `forge build`
- [ ] Run `00_DeployHook.s.sol` → copy `HOOK_ADDR` to `.env`
- [ ] Run `01_CreatePoolAndAddLiquidityPegHook.s.sol`
- [ ] Verify pool state via `cast` calls
- [ ] Run `02_AddLiquidity.s.sol` / `03_Swap.s.sol` as needed

---

## License

MIT
