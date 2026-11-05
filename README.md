# Inside the Block: How Solana Validators Order Transactions (Post-Alpenglow Mainnet Study)

> **Superteam Ukraine Bounty Submission** — Empirical measurement and reproducible harness investigating how Solana Mainnet validators across **7 distinct client software & fork versions** (`0.1.1`, `26.10.5`, `26.10.6`, `4.3.2`, `4.4.0`, `4.4.0-rc.1`, `4.5.0-alpha.2`) order transactions inside a block after the **October 21 Alpenglow Upgrade**.

---

## 1. Executive Summary & Core Findings

For every validator analyzed on Solana Mainnet (Post-Alpenglow, November 5, 2026), we tested the theoretical priority-ordering hypothesis:

$$\text{Scheduler Priority Score} \approx \frac{\text{Total Fee ( Base Fee + Priority Fee )}}{\text{Estimated Cost Units (CU Limit + Account/Signature Costs)}}$$

### Key Conclusions Across 8 Mainnet Validators (7 Client Versions)
1. **Global Block Index Is NOT Monotonically Sorted by Fee/Cost ($\rho \in [+0.009, +0.188]$):**
   Across all 8 validators (spanning Firedancer/Frankendancer `0.1.1` & `26.10.x` and Agave/Jito-Solana `4.3.2`, `4.4.0`, `4.4.0-rc.1`, `4.5.0-alpha.2`), the block-wide Spearman rank correlation between transaction index ($0 \dots N$) and descending `fee_per_cost_unit` is weakly positive ($\rho = +0.0092$ to $+0.1877$). Why? Because Solana leaders do **not** wait until the end of the 400ms slot to batch-sort the entire block. Instead, they execute transactions continuously in **streaming PoH ticks / banking stage batches** across multiple parallel worker threads.
2. **Early Block Quartile ($Q_1$) Carries Significantly Higher Fee/Cost Density Than Late Quartile ($Q_4$):**
   Transactions buffered *prior* to the start of a leader's window or arriving at the top of a PoH tick burst are drained from the priority queue first. For example, on Firedancer/Frankendancer `26.10.6` (`GZ4U21...`, Slot `465777655`), the median `fee_per_cost_unit` in the first 25% of the block ($Q_1$) is **`1.0724` lamports/CU**, compared to **`0.4808` lamports/CU** in the final 25% ($Q_4$)—a **2.23x priority premium** at the top of the block.
3. **Client Software Differences (`Firedancer 0.1.1 / 26.10.x` vs. `Agave 4.3 / 4.4 / 4.5`):**
   - **Pure Firedancer (`0.1.1`, `FBbqKvw...`) & Frankendancer (`26.10.6`, `GZ4U21...`)** exhibit the strongest top-of-block priority sorting ($\rho = +0.1877$ and $\rho = +0.1803$), reflecting tight priority-queue draining at the start of the slot before late-arriving TPU traffic interleaves.
   - **Agave / Jito-Solana `4.3.2`–`4.4.0` (`8gDfqH...`, `EXckih...`, `Lua1fx...`)** show lower global rank correlation ($\rho = +0.0092$ to $+0.1057$) due to multi-thread banking-stage worker interleaving: four parallel non-vote banking threads pull non-conflicting transactions concurrently, so a low-fee uncontested transaction on Thread B lands at an earlier block index than a high-fee contended transaction waiting on a write-lock on Thread A.
   - **Same-Write-Lock Contention Monotonicity (`0.5008` – `0.5669`):** Even when two transactions lock the same writable account within the same 400ms slot, priority ordering holds only `50.1%–56.7%` of the time across the whole slot because arrival time across the 64 PoH ticks dominates over priority score unless both transactions sit in the scheduler buffer simultaneously during the same micro-batch.

---

## 2. One-Command Reproducibility (Docker Compose)

This repository is engineered to be **100% reproducible with a single command**, running in **safe `--dry-run` / `--verify-only` mode by default** and never storing keys in the repository.

### Default Run (Verify Cached Mainnet Measurements — Zero Network Spend)
```bash
docker compose up --build
```

### Live Mainnet Dry-Run (Discover Current Leaders Across >=3 Client Versions, Build Probe Ladders, & Parse Live Blocks)
```bash
docker compose run --rm block-ordering-harness --validators 8
```

### Explicit Live Transaction Broadcasting Mode (Behind `--live` Flag + Strict `0.05 SOL` Spend Cap)
Keys are loaded **exclusively** via environment variable (`SOLANA_KEYPAIR_JSON`) or read-only Docker volume (`/keys/id.json`):
```bash
# Place keypair in ./keys/id.json (gitignored) or pass SOLANA_KEYPAIR_JSON
docker compose run --rm block-ordering-harness --live --max-spend-sol 0.05
```

---

## 3. Experimental Design & "What You Will Have to Account For"

### Why This Design?
Our harness ([`src/measure_block_ordering.py`](src/measure_block_ordering.py)) combines:
1. **Cluster Version Telemetry (`getClusterNodes` + `getSlotLeaders`):** Dynamically maps active Mainnet leader slots to exact validator client software versions (`0.1.1`, `26.10.5`, `26.10.6`, `4.3.2`, `4.4.0`, `4.4.0-rc.1`, `4.5.0-alpha.2`).
2. **Post-Alpenglow `v1` & `v0`/`legacy` Transaction Parser:** Supports both native Alpenglow `version: 1` `transactionConfig` (`priorityFee`, `computeUnitLimit`, `loadedAccountsDataSizeLimit`) and `ComputeBudget111111111111111111111111111111` instructions (`SetComputeUnitLimit` tag `0x02`, `SetComputeUnitPrice` tag `0x03`).
3. **Probe Ladder Generator (`build_dry_run_probe_ladder`):** Builds 10-transaction probe bursts per validator across 5 priority fee tiers (`1,000` to `1,000,000` micro-lamports/CU) and 2 contention modes (`independent_writelock` vs. `shared_account_contention`), guarded by `SpendCapEnforcer` (hard cap $\le 50,000,000$ lamports = `0.05 SOL`).

### Handling Each Required Confounding Factor
| Factor | How Our Design Handles It |
| :--- | :--- |
| **1. Leader Schedule & Leader Types** | Queries `getSlotLeaders` over a 2,500-slot Mainnet window and cross-references `getClusterNodes` to stratify leaders across 7 distinct client versions (`Firedancer 0.1.1`, `Frankendancer 26.10.5/26.10.6`, `Agave/Jito 4.3.2`, `4.4.0`, `4.4.0-rc.1`, `4.5.0-alpha.2`). Targets the final slots (`slots[-4:]`) of each 4-slot leader window to minimize handoff boundary jitter. |
| **2. Path of a Transaction (Backend $\to$ RPC $\to$ Stake-Weighted QUIC TPU $\to$ Leader)** | Recognizes that public RPC nodes forward transactions over QUIC streams with variable stake-weighted QoS (SWQoS) and geographic latency. In `--dry-run` mode, we build the exact probe ladder and evaluate landed transactions directly from the leader's committed block (`getBlock`), measuring both global block-index correlation and within-quartiles ($Q_1$ vs $Q_4$) priority density. |
| **3. Interaction of Transactions With Each Other (Write-Lock Contention)** | Separates uncontested parallelizable transactions from transactions contending on shared writable accounts (`same_writelock_pairs_evaluated`). Non-conflicting transactions bypass each other across parallel banking threads; only transactions contending on the same account lock are serialized by the scheduler's lock-free/prio-graph queue. |
| **4. Competition Inside the Block & Jito Exclusion** | Per bounty rules, we explicitly filter out `Vote111111111111111111111111111111111111111` transactions (which use dedicated vote banking threads) and isolate transactions touching the 8 canonical **Jito Tip Accounts** (`96gYZG...`, `HFqU5x...`, etc.) so out-of-protocol Jito bundle auctions do not corrupt measurement of the leader's native scheduler. |
| **5. Send Order vs. Arrival Order** | Probe ladders alternate priority tiers and contention modes while recording `send_order_index`. Because QUIC packet arrival order at the leader's `sigverify` stage differs from client send order by 5–80ms of network jitter, any rule that holds strictly inside a single PoH tick decays into arrival-time ordering across different ticks. |
| **6. Noise vs. Rule** | Rather than forcing a false deterministic claim, we quantify both the **deterministic signal** ($Q_1$ vs. $Q_4$ fee/cost ratio up to `2.23x` and positive Spearman $\rho$) and the **arrival-time / multi-thread noise** (`~43–49%` inversions on contended write-locks across the full 400ms slot). |
| **7. Post-Alpenglow Upgrade Consistency** | All measurements were taken on **November 5, 2026** (strictly **after** the October 21 Alpenglow upgrade) with `maxSupportedTransactionVersion: 1`. Zero pre-Alpenglow data is mixed. |

### What This Design Does NOT Separate
To maintain complete scientific honesty:
1. **Ingress Timestamp at the Leader's QUIC Socket vs. Scheduler Queue Wait Time:** From `getBlock` RPC data alone (and even when sending from an external client without kernel-level eBPF probes on the validator host), an external observer cannot observe the exact nanosecond a packet cleared `sigverify` inside the leader. Thus, when a low-fee transaction lands at index `10` and a high-fee transaction lands at index `450`, external block data alone cannot separate *"the scheduler ignored priority"* from *"the high-fee transaction arrived 200ms later during PoH tick 35."*
2. **Private SWQoS / Staked Relay Forwarding vs. Public TPU Ingress:** Validators running Jito-Solana or custom staked QUIC forwarders may prioritize packet ingestion before transactions ever enter the central scheduler buffer.

---

## 4. Verifiable Mainnet Dataset & Judge Verification Commands

All raw measurement data is saved in [`data/mainnet_measurements.json`](data/mainnet_measurements.json) and detailed in [`REPORT.md`](REPORT.md). Judges can verify any block and signature directly against Solana Mainnet RPC:

```bash
curl -s https://api.mainnet-beta.solana.com -X POST -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "getBlock",
  "params": [
    465777655,
    {"encoding": "json", "maxSupportedTransactionVersion": 1, "transactionDetails": "signatures"}
  ]
}' | jq '.result | {blockhash, blockHeight, first_3_sigs: .signatures[:3]}'
```
