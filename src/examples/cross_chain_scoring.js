/**
 * Cross-Chain Swap Scoring — example JS scoring for multi-chain intent execution.
 *
 * Scores plans that span multiple chains (e.g. swap on Ethereum + bridge + action on BT EVM).
 * Uses `context.simulation.leg_results` to evaluate each leg independently and
 * `context.simulation.bridge_estimate` for bridge cost/duration assessment.
 *
 * Plan metadata convention:
 *   metadata.cross_chain = true
 *   metadata.legs = [
 *     { leg_id: 0, chain_id: 1, type: "source" },
 *     { leg_id: 1, chain_id: 1, type: "bridge", bridge_protocol: "mock" },
 *     { leg_id: 2, chain_id: 964, type: "destination" },
 *   ]
 */

const config = {
  score_threshold: 0.5,
  on_chain_threshold: 5000,
  max_gas: 800000,
};

const manifest = {
  intent_functions: [
    {
      name: "execute",
      description: "Cross-chain token swap via bridge",
      params: {
        input_token:  { type: "address", required: true, description: "Source token address" },
        output_token: { type: "address", required: true, description: "Destination token address" },
        input_amount: { type: "uint256", required: true, description: "Amount in wei" },
        dest_chain_id: { type: "uint256", required: true, description: "Destination chain ID" },
        min_output:   { type: "uint256", required: false, source: "quote", quote_field: "suggested_min_output" },
      },
      example_params: {
        input_token: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        output_token: "0x77E06c9eCCf2E797fd462A92b6D7642EF85b0A44",
        input_amount: "1000000000000000000",
        dest_chain_id: "964",
      },
    },
  ],
};

/**
 * Score a cross-chain execution plan.
 *
 * @param {object} plan  - ExecutionPlan with metadata.legs
 * @param {object} state - IntentState (flattened with order params)
 * @param {object} context - { simulation, state, oracle }
 * @returns {{ score: number, breakdown: object }}
 */
function score(plan, state, context) {
  const sim = context.simulation || {};
  const legResults = sim.leg_results || {};
  const bridgeEstimate = sim.bridge_estimate || {};
  const isCrossChain = plan.metadata && plan.metadata.cross_chain;

  // Single-chain fallback
  if (!isCrossChain) {
    return scoreSingleChain(plan, state, context);
  }

  const breakdown = {};
  let total = 0;

  // 1. Source leg success (40% weight)
  const sourceLeg = legResults[0] || {};
  if (sourceLeg.success) {
    breakdown.source_execution = 0.4;
    total += 0.4;
  } else {
    breakdown.source_execution = 0;
    return { score: 0, breakdown, reason: "Source leg failed: " + (sourceLeg.error || "unknown") };
  }

  // 2. Bridge cost efficiency (20% weight)
  if (bridgeEstimate && bridgeEstimate.estimated_output > 0) {
    const feeRatio = (bridgeEstimate.fee || 0) / bridgeEstimate.amount_in;
    // Perfect score at 0% fee, zero at 1% fee
    const bridgeScore = Math.max(0, 1 - feeRatio * 100);
    breakdown.bridge_efficiency = +(bridgeScore * 0.2).toFixed(4);
    total += breakdown.bridge_efficiency;
  } else {
    breakdown.bridge_efficiency = 0.1; // Partial credit if no estimate
    total += 0.1;
  }

  // 3. Destination leg success (25% weight)
  const legs = (plan.metadata && plan.metadata.legs) || [];
  const destLeg = legs.find(l => l.type === "destination");
  if (destLeg) {
    const destResult = legResults[destLeg.leg_id] || {};
    if (destResult.success) {
      breakdown.dest_execution = 0.25;
      total += 0.25;
    } else if (destResult.success === undefined) {
      // Dest not simulated (might be placeholder) — partial credit
      breakdown.dest_execution = 0.15;
      total += 0.15;
    } else {
      breakdown.dest_execution = 0;
    }
  } else {
    breakdown.dest_execution = 0.25; // No dest leg = bridge-only, full credit
    total += 0.25;
  }

  // 4. Gas efficiency (15% weight)
  const totalGas = sim.gas_used || 0;
  const maxGas = config.max_gas || 800000;
  if (totalGas > 0 && totalGas <= maxGas) {
    const gasScore = 1 - (totalGas / maxGas);
    breakdown.gas_efficiency = +(gasScore * 0.15).toFixed(4);
    total += breakdown.gas_efficiency;
  } else {
    breakdown.gas_efficiency = 0.05;
    total += 0.05;
  }

  total = Math.min(total, 1.0);

  return {
    score: +total.toFixed(4),
    breakdown,
  };
}

function scoreSingleChain(plan, state, context) {
  const sim = context.simulation || {};
  if (!sim.success) {
    return { score: 0, breakdown: { error: "simulation_failed" } };
  }
  return { score: 0.7, breakdown: { base: 0.7 } };
}

module.exports = { config, manifest, score };
