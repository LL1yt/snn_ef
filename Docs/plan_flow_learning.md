# Flow Learning Plan v0

Goal: introduce simple, robust, headless learning for the Flow router to (a) match a target boundary histogram and (b) stabilize spiking behavior, while nudging particles to finish exactly on the radius R.

Scope (phase v0):
- Online updates with small number of global parameters; no backprop through dynamics.
- CPU-only; integrate with ConfigCenter + LoggingHub; deterministic seeds.
- Keep Capsule fixed; learning runs as a separate CLI routine and exports checkpoints and snapshots.

Key terms
- Bin: angular sector index on the boundary circle in [0 .. B-1], where B = capsule.base = router.flow.projection.bins. Computed by FlowProjector.binIndex(theta, bins).
- Completion: particle projected to boundary (r >= R) with final event (pos, energy, spike flag, projected bin).
- Tracked streams: a small subset of particles (e.g., first 2-4 ids) for UI trails and per-step history.

Target signals (v0)
- Target boundary distribution T[b]. Sources:
  1) capsule-digits (default): from Capsule energies for the input block, map base-B digits (energies = digits+1) into desired per-bin totals; optionally distribute by initial seed angle index; and/or
  2) file/cli provided reference bins (CSV/JSON) for benchmarking.

Weighted aggregator ("умное среднее")
Multiple streams can complete into the same bin. We form a smart average per bin with per-completion weights combining closeness to boundary and energy correctness:
- For each completion j → (bin k_j, position r_j, energy E_j, spiked_j):
  - Distance weight: w_dist = exp(-|r_j - R| / sigma_r), sigma_r ~ 0.25·R (configurable).
  - Energy weight: if target per-bin energy T[k_j] exists, w_energy = exp(-|E_j - T[k_j]| / sigma_e); else use w_energy = E_j / (max(E)+eps) as a magnitude proxy (eps small).
  - Optional alignment weight (seed → bin goal): w_align = exp(-angular_distance(b_goal_j, k_j) / tau), where b_goal_j is the seed’s initial bin index.
  - Combine: w_j = (w_dist^alpha) * (w_energy^beta) * (w_align^gamma). Normalize per bin: W = sum_j w_j, then y_hat[b] = sum_{j in S_b} (w_j * E_j) / max(W, eps).
This y_hat[b] becomes the bin estimate used in loss; it prioritizes particles that hit closer to the boundary and with more compatible energy.

Losses (v0)
- Bin loss: L_bins = sum_b (y_hat[b] - T[b])^2 + lambda_g * ||g||_2^2,
  where g[b] is a per-bin gain applied on projection (outputs[b] += g[b]*E), initialized to 1.0.
- Spike-rate loss: L_spike = (r_obs - r_tgt)^2, where r_obs is per-step (or per-epoch) spike fraction across particles, r_tgt from config (e.g., 10–25%).
- Boundary loss: L_boundary = mean_j max(0, |r_j - R| - eps), reducing average radial miss at completion (eps small). This will steer outward drift and spike kick.
- Total: L = L_bins + w_spike * L_spike + w_boundary * L_boundary.

Learnable parameters (v0)
- Per-bin gains g[b] (length = B), applied only at projection accumulation time.
- LIF: threshold θ, decay ρ (optional) for global stability of spikes.
- Dynamics: radialBias β_r and spikeKick κ (scale of outward kick upon spike). Keep bounds: β_r ∈ [0, 1], κ ∈ [0, 1].

Update rules (online, SGD/heuristic)
- Gains: g[b] ← clamp(g[b] - η_g * 2*(y_hat[b] - T[b]) * d y_hat[b]/d g[b]). In v0, approximate d y_hat[b]/d g[b] ≈ mean(E_j) over S_b (or run a second pass to accumulate effective influence). Simpler: g[b] ← g[b] - η_g*(y_hat[b] - T[b]) with small η and clip g[b] to [g_min, g_max].
- LIF threshold θ (spike-rate tuner): if r_obs > r_tgt + m, increase θ by η_θ; if below, decrease θ by η_θ. Use momentum and clamps θ ∈ [θ_min, θ_max]. Optionally adjust decay ρ inversely.
- Radial bias β_r (boundary reach): if many particles fail to reach boundary by T (completion rate low) or avg miss > eps, increase β_r by η_r. If nearly all complete early (too aggressive), decrease β_r slightly. Clamp to [0, 1].
- Spike kick κ: increase if boundary miss persists despite spikes; decrease if overshoot patterns degrade bin match (heuristic based on L_bins trend).

Learning loop (headless CLI)
1) Sampling: choose input texts (dataset path or repeat capsule.pipelineExampleText N times), compute Capsule energies.
2) Seeds: FlowSeeds.makeSeeds.
3) Run FlowRouter with stepWithEvents; collect per-step events and completions.
4) Aggregate: compute y_hat[b] with smart weights; compute T[b].
5) Loss: L_bins, L_spike, L_boundary; log metrics.
6) Update parameters: g, θ, β_r, κ with small step sizes.
7) Snapshots: write checkpoint (router.flow.learning.json) and pipeline snapshot with flow; append to Logs.
8) Repeat epochs until convergence (or epochs limit).

Config additions (ConfigRoot.Router.flow.learning)
- enabled: Bool
- epochs: Int, stepsPerEpoch: Int (or T already controls steps)
- targetSpikeRate: Double (0..1)
- lr: { gain: Double, lif: Double, dynamics: Double }
- weights: { spike: Double, boundary: Double }
- bounds: { theta: [min,max], radialBias: [min,max], spikeKick: [min,max], gain: [min,max] }
- aggregator: { sigma_r, sigma_e, alpha, beta, gamma, tau }
- targets: { type: "capsule-digits" | "file", path?: String }

CLI interface
- energetic-cli learn [--epochs N] [--dataset PATH] [--lr.gain x --lr.lif y --lr.dyn z] [--target-spike-rate r] [--save-every K]
- Outputs: Artifacts/Checkpoints/learning_epoch_XXX.json (parameters + metrics), Artifacts/pipeline_snapshot.json (with flow section), Logs/ with per-epoch summaries.

Data structures
- RouterLearningState { epoch, params { g[], theta, radialBias, spikeKick }, metrics { L_bins, L_spike, L_boundary, completionRate, spikeRate, y_hat stats } }
- Extend ConfigPipelineSnapshot.flow to optionally include per-epoch metrics summary.

Metrics to log
- Per-epoch: L, L_bins, L_spike, L_boundary, spikeRate, completionRate, mean |r-R|, nonzero bins, top bins.
- Param deltas: Δg (mean/var), Δθ, Δβ_r, Δκ.

Testing strategy
- Unit: aggregator weights and normalization (sigma_r/e, alpha/beta/gamma).
- Unit: spike-rate tuner moves θ in the correct direction toward target on synthetic spike streams.
- Unit: gains update reduces L2 to a synthetic T[b] in few epochs.
- Integration: headless learn on a fixed seed and short T shows monotonic decrease of L_bins and non-increasing boundary miss.

UI hooks (optional v0.1)
- Live metrics view in EnergeticVisualizationDemo: plot L over epochs; overlay updated g[b] on histogram; toggle learning on/off.

Phased delivery
- A: Scaffolding (config, CLI command, logging, checkpoints) + aggregator implementation.
- B: Spike-rate tuner + per-bin gains with L_bins; export metrics.
- C: Boundary nudging via β_r and κ with L_boundary; safety clamps and early stopping.
- D: UI overlays for metrics; polish; docs.

Notes & Rationale
- The smart averaging ensures when multiple streams hit the same bin, those closest to the true boundary and energy target dominate the update, reducing noise from stray paths.
- Parameter updates are conservative, bounded, and logged for reproducibility.
- We avoid differentiating through the simulator in v0; future work can introduce differentiable surrogates or policy-gradient style updates.
