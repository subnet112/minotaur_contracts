/**
 * Alpha Yield Optimisation — scoring for the AlphaYieldApp intent on BT EVM (964).
 *
 * WHAT IS BEING COMPETED. A wrapped-alpha vault position must be delegated to
 * some validator, and which one changes what wAlpha holders earn. Solvers
 * propose a validator from the vault's allowlist; the best proposal wins.
 *
 * THIS MODULE RE-DERIVES THE ANSWER, IT DOES NOT TRUST THE SIMULATION.
 * The sandbox bridges `ethCall(chainId, to, data, blockTag)` into the isolate
 * (eth_call is on the runner's RPC method allowlist), so scoring reads the
 * metagraph precompile at 0x…0802 directly and recomputes every candidate's
 * rate from chain state. The on-chain score and this score are then two
 * independent derivations of the same fact, and a disagreement between them is
 * itself a signal — reported as `agrees_with_chain` rather than silently
 * averaged away.
 *
 * WHY THIS IS NOT SCORED LIKE THE DEX. The aggregator uses a relative pairwise
 * rule because "best swap" has no absolute yardstick. Here there IS a knowable
 * optimum at every block, so the score is absolute and bounded 0..1:
 *
 *     score = (rate(chosen) - rate(worst)) / (rate(best) - rate(worst))
 *
 * normalised across the allowlist — the worst eligible pick scores 0, the best
 * scores 1. Same shape as `linearScore(value, worst, best)` in the rebalance
 * intent template, which is the established pattern for auto-triggered intents.
 *
 * RATE IS DILUTION-AWARE. This is the part that is easy to get wrong:
 *
 *     rate(uid) = dividends(uid) / (stake(uid) + position moving in)
 *
 * `dividends / stake` alone is a MARGINAL rate — what the next infinitesimal
 * unit earns — and it is actively misleading for placing a large position.
 * Measured on SN112 at block 8893344: uid 230 (8,659 dividends on 8,800,003
 * stake) scores ~12,500x better than uid 0 on the marginal rate, but once the
 * vault's 445.8e9 alpha lands on it the position earns 59% LESS than uid 0
 * would have. The incumbent's reported stake already includes the vault's
 * position, so it is not added twice.
 *
 * NO GAS TERM, DELIBERATELY. The App ignores `plan.calls` — a plan carries only
 * a recommendation and the contract performs the move itself — so gas is fixed
 * by the App, not chosen by the solver. Scoring it would be noise.
 *
 * WHAT NOTHING HERE CAN SEE. Delegate take is not exposed by any precompile, so
 * every rate is pre-take and a validator charging 100% looks identical to one
 * charging nothing. That hole is closed outside this function — by the vault's
 * allowlist (take vetted off-chain before eligibility) and by a performance fee
 * charged on realised share-price growth. Do not add a take term; there is no
 * honest source for one.
 */

const METAGRAPH = "0x0000000000000000000000000000000000000802";
const CHAIN_ID = 964;

// keccak256 of the IMetagraph signatures, computed not guessed — an off-by-one
// selector reads a different function and scores confidently wrong.
const SEL = {
  hotkey: "0x3adc89da",    // getHotkey(uint16,uint16)
  stake: "0xe7c7c4b5",     // getStake(uint16,uint16)
  dividends: "0x82da0b5d", // getDividends(uint16,uint16)
  validator: "0x58dd9945", // getValidatorStatus(uint16,uint16)
};

const config = {
  score_threshold: 0.5,
  on_chain_threshold: 5000,
  max_gas: 400000,
  /** Bounds the RPC work per scoring run: candidates + a sanity scan. */
  max_candidate_reads: 16,
};

const manifest = {
  intent_functions: [
    {
      name: "optimizeYield",
      description:
        "Choose the highest-yielding allowlisted validator for a wrapped alpha market",
      params: {
        netuid: {
          type: "uint256",
          required: true,
          description: "Subnet whose wrapped market is being re-delegated",
        },
      },
      example_params: { netuid: "112" },
      /**
       * The plan carries a recommendation, not calls. `plan.calls` is ignored on
       * chain; send an empty array.
       *   plan.metadata = abi.encode(bytes32 hotkey, uint16 uid)
       * Read `AlphaYieldApp.survey(netuid)` for the candidate set, live
       * dilution-aware rates and the cooldown.
       */
      plan_metadata: {
        hotkey: { type: "bytes32", required: true, description: "Chosen validator hotkey" },
        uid: { type: "uint16", required: true, description: "Its current metagraph uid" },
      },
      /**
       * Perpetual: the subnet re-opens this order after every fill while
       * execution_count < max_executions, so Minotaur decides WHEN to move the
       * stake.
       *
       * Do not hardcode the cooldown — read `AlphaVault.rebalanceCooldown()` and
       * build the order's `cooldown` from it. The two are NOT redundant: the
       * base's clock is keyed on order.orderId (how often may this ORDER fill),
       * the vault's on the netuid (how often may this MARKET move). A second
       * order aimed at the same market carries its own base clock, and
       * scoreIntent reaches the vault with no base checks at all. Setting the
       * order shorter than the vault's just reverts fills with RebalanceTooSoon.
       */
      perpetual: true,
      cooldown_source: "AlphaVault.rebalanceCooldown()",
      min_cooldown_seconds: 3600,
    },
  ],
};

/**
 * @param {object} plan    - ExecutionPlan; metadata carries {hotkey, uid}
 * @param {object} state   - IntentState flattened with order params (netuid)
 * @param {object} context - { simulation, state, oracle }
 * @returns {{score: number, breakdown: object, reason?: string}}
 */
async function score(plan, state, context) {
  const sim = (context && context.simulation) || {};
  const breakdown = {};

  // A plan that does not survive simulation is worth nothing, whatever it claimed.
  if (!sim.success) {
    return {
      score: 0,
      breakdown: { execution: 0 },
      reason: "simulation_failed: " + (sim.error || "unknown"),
    };
  }
  breakdown.execution = 0.15;

  const netuid = Number(pick(state, "netuid") || 0);
  const chosenUid = Number(pick(sim, "uid"));
  const candidates = readCandidates(sim);

  // Independent derivation from chain state. If the RPC bridge is unavailable
  // the harness still gets a score, but it is explicitly marked unverified
  // rather than silently trusted.
  let derived = null;
  try {
    derived = await deriveRates(netuid, candidates, num(pick(sim, "position")));
  } catch (e) {
    breakdown.verification = "unavailable: " + String(e && e.message ? e.message : e);
  }

  if (!derived) {
    const fallback = clamp01(num(pick(sim, "score")) / 10000);
    return {
      score: round4(clamp01(breakdown.execution + fallback * 0.85)),
      breakdown: Object.assign(breakdown, { optimality: round4(fallback * 0.85), verified: false }),
      reason: "scored from on-chain result without independent verification",
    };
  }

  const { best, worst, byUid } = derived;
  if (!(best > 0)) {
    return {
      score: 0,
      breakdown: Object.assign(breakdown, { optimality: 0 }),
      reason: "no_scorable_yield: no allowlisted validator has dividends",
    };
  }

  const chosenRate = byUid[chosenUid] || 0;
  const optimality = best === worst ? 1 : clamp01((chosenRate - worst) / (best - worst));
  breakdown.optimality = round4(optimality * 0.85);

  // Cross-check: does our independent derivation agree with what the contract
  // scored? Divergence means the chain moved between simulation and scoring, or
  // that one of the two is reading different state — worth surfacing either way.
  const onChain = clamp01(num(pick(sim, "score")) / 10000);
  breakdown.agrees_with_chain = Math.abs(onChain - optimality) < 0.02;
  breakdown.on_chain_optimality = round4(onChain);
  breakdown.derived_optimality = round4(optimality);
  breakdown.chosen_rate = chosenRate;
  breakdown.best_rate = best;
  breakdown.worst_rate = worst;
  breakdown.verified = true;

  const total = clamp01(breakdown.execution + breakdown.optimality);
  return { score: round4(total), breakdown };
}

/**
 * Re-read every candidate from the metagraph and rank them. Bounded by
 * `config.max_candidate_reads`: the vault caps its allowlist at 16, so this is
 * at most 48 eth_calls and cannot grow without a governance change.
 */
async function deriveRates(netuid, candidates, position) {
  if (typeof ethCall !== "function") throw new Error("no RPC bridge in sandbox");
  const list = candidates.slice(0, config.max_candidate_reads);
  if (!list.length) throw new Error("no candidate set in simulation output");

  const byUid = {};
  let best = 0;
  let worst = Infinity;
  for (const c of list) {
    const uid = Number(c.uid);
    const isVali = await callBool(SEL.validator, netuid, uid);
    let rate = 0;
    if (isVali) {
      const stake = await callUint(SEL.stake, netuid, uid);
      const div = await callUint(SEL.dividends, netuid, uid);
      // The incumbent already carries the position in its reported stake.
      const denom = stake + (c.incumbent ? 0 : position);
      rate = denom > 0 ? (div * 1e18) / denom : 0;
    }
    byUid[uid] = rate;
    if (rate > best) best = rate;
    if (rate < worst) worst = rate;
  }
  return { best, worst: worst === Infinity ? 0 : worst, byUid };
}

function word(n) {
  return BigInt(n).toString(16).padStart(64, "0");
}

async function callUint(sel, netuid, uid) {
  const res = await ethCall(CHAIN_ID, METAGRAPH, sel + word(netuid) + word(uid), "latest");
  if (!res || res === "0x") return 0;
  return Number(BigInt(res));
}

async function callBool(sel, netuid, uid) {
  return (await callUint(sel, netuid, uid)) === 1;
}

/** Candidate set as the App's survey/event reports it. */
function readCandidates(sim) {
  const raw = pick(sim, "candidates") || pick(sim, "uids") || [];
  if (!Array.isArray(raw)) return [];
  return raw.map((c) =>
    typeof c === "object" ? c : { uid: c, incumbent: false }
  );
}

/** Pull a value the harness may surface flat, under an event, or under returns. */
function pick(src, key) {
  if (!src) return undefined;
  if (src[key] !== undefined) return src[key];
  const ev = src.events && src.events.YieldOptimized;
  if (ev && ev[key] !== undefined) return ev[key];
  const ret = src.return_values || src.raw_params || src.typed_context || {};
  return ret[key];
}

function num(v) {
  if (v === undefined || v === null) return 0;
  const n = typeof v === "string" ? Number(v) : Number(v);
  return Number.isFinite(n) ? n : 0;
}

function clamp01(x) {
  if (!Number.isFinite(x) || x < 0) return 0;
  return x > 1 ? 1 : x;
}

function round4(x) {
  return +Number(x).toFixed(4);
}

module.exports = { config, manifest, score };
