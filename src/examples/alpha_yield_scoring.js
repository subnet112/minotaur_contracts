/**
 * Alpha Yield Optimisation — scoring for the AlphaYieldApp intent on BT EVM (964).
 *
 * WHAT IS BEING COMPETED. A wrapped-alpha vault position must be delegated to
 * some validator, and which one changes what wAlpha holders earn. Solvers
 * propose a validator from the vault's allowlist; the best proposal wins.
 *
 * WHY THIS IS NOT SCORED LIKE THE DEX. The aggregator uses a relative pairwise
 * rule because "best swap" has no absolute yardstick — you only know a route is
 * good by beating another route. Here there IS a knowable optimum at every
 * block: the highest-yielding validator on the allowlist. So the score is an
 * absolute fraction of that optimum, bounded 0..1, and a solver that finds the
 * best answer scores 1.0 whether or not anyone else competed that round.
 *
 *     optimality = rate(chosen) / rate(best allowlisted)
 *     rate(uid)  = dividends(uid) / stake(uid)      [IMetagraph, 0x…0802]
 *
 * NO GAS TERM, DELIBERATELY. The App ignores `plan.calls` — a plan here carries
 * only a recommendation, and the contract performs the move itself, so gas is
 * fixed by the App rather than chosen by the solver. Scoring it would add noise
 * that no solver can act on.
 *
 * WHAT THIS CANNOT SEE. Delegate take is not exposed by any precompile, so
 * `rate` is a pre-take figure and a validator charging 100% scores like one
 * charging nothing. That hole is closed outside this function — by the vault's
 * allowlist (take vetted off-chain before a hotkey is eligible) and by a
 * performance fee charged on realised share-price growth. Do not add a take
 * term here; there is no honest source for it.
 */

const config = {
  score_threshold: 0.5,
  on_chain_threshold: 5000,
  max_gas: 400000,
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
       * The plan carries the recommendation, not calls. `plan.calls` is ignored
       * on chain; send an empty array.
       *   plan.metadata = abi.encode(bytes32 hotkey, uint16 uid)
       * Read `AlphaYieldApp.survey(netuid)` for the candidate set, live rates and
       * the cooldown — everything needed to build a plan, with no indexer.
       */
      plan_metadata: {
        hotkey: { type: "bytes32", required: true, description: "Chosen validator hotkey" },
        uid: { type: "uint16", required: true, description: "Its current metagraph uid" },
      },
    },
  ],
};

/**
 * @param {object} plan    - ExecutionPlan; metadata carries {hotkey, uid}
 * @param {object} state   - IntentState flattened with order params (netuid)
 * @param {object} context - { simulation, state, oracle }
 * @returns {{score: number, breakdown: object, reason?: string}}
 */
function score(plan, state, context) {
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

  const chosenRate = num(pick(sim, "chosenRate"));
  const bestRate = num(pick(sim, "bestRate"));

  // No allowlisted validator is earning: every choice is indistinguishable, so
  // there is nothing to reward. The contract reverts in this case; if a
  // simulation still reaches here, decline to score rather than invent a number.
  if (!(bestRate > 0)) {
    return {
      score: 0,
      breakdown: Object.assign(breakdown, { optimality: 0 }),
      reason: "no_scorable_yield: no allowlisted validator has dividends",
    };
  }

  const optimality = clamp01(chosenRate / bestRate);
  breakdown.optimality = round4(optimality * 0.85);

  const total = clamp01(breakdown.execution + breakdown.optimality);
  return {
    score: round4(total),
    breakdown: Object.assign(breakdown, {
      chosen_rate: chosenRate,
      best_rate: bestRate,
      optimality_ratio: round4(optimality),
    }),
  };
}

/** Pull a value the harness may surface either flat or under the event payload. */
function pick(sim, key) {
  if (sim[key] !== undefined) return sim[key];
  const ev = sim.events && sim.events.YieldOptimized;
  if (ev && ev[key] !== undefined) return ev[key];
  const ret = sim.return_values || {};
  return ret[key];
}

function num(v) {
  if (v === undefined || v === null) return 0;
  const n = typeof v === "string" ? Number(v) : v;
  return Number.isFinite(n) ? n : 0;
}

function clamp01(x) {
  if (!Number.isFinite(x) || x < 0) return 0;
  return x > 1 ? 1 : x;
}

function round4(x) {
  return +x.toFixed(4);
}

module.exports = { config, manifest, score };
