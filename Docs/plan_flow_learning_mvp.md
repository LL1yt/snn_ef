# Flow Learning MVP Plan

Status: proposed
Owner: EnergeticCore
Scope: minimal working end-to-end learning loop for Flow router (CPU, headless)

## Goal (MVP)
Make the learning pipeline actually affect routing outcomes end-to-end with deterministic behavior, using the existing loop, config, and CLI. The MVP must:
- Apply learnable parameters (gains, spikeKick, lif threshold, radial bias) during simulation.
- Produce measurable loss changes across epochs (not necessarily monotonic, but responsive).
- Save checkpoints and a summary.
- Remain headless-safe and fail-fast on invalid config.

## Non-goals (MVP)
- No GPU/Metal kernels.
- No differentiable backprop through dynamics.
- No UI integration.
- No changes to Capsule encoding/decoding.

## Current gaps to close
1) `gains[]` is used in loss computation but **not applied** in projection accumulation.
2) `spikeKick` is **learned but ignored** in `FlowRouter` (hardcoded factor).
3) Updating parameters **resets RNG state**, reducing determinism within an epoch.
4) Seed layout `disk` is accepted in config but not implemented (optional for MVP).

## MVP steps (implementation order)

### 1) Apply gains during projection
**Why:** bin losses can’t shape outputs unless gains affect accumulation.

Actions:
- Extend `FlowConfig` to carry optional `projectionGain` mode (or pass gains into projector via router/learning loop).
- Update `FlowProjector.projectIfNeeded` to apply per-bin gains: `outputs[b] += gains[b] * energy`.
- Update call sites:
  - `FlowRouter.step` and `stepWithEvents` should accept optional `gains` (default all 1.0).
  - Learning loop passes `params.gains` for training epochs.
  - Non-learning runs default to gains=1.0 (no change in behavior).

Definition of done:
- Changing gains in learning loop changes output histograms.

### 2) Wire `spikeKick` into dynamics
**Why:** learning updates `spikeKick` but it never changes behavior.

Actions:
- Add `spikeKick` to `FlowConfig.Dynamics`.
- Use `spikeKick` in `FlowRouter` when spiked (replace hardcoded `0.5`).
- Ensure ConfigCenter provides a value (default from config; if absent, set safe default).

Definition of done:
- `spikeKick` affects velocity updates and metrics.

### 3) Preserve RNG state across parameter updates
**Why:** reinitializing router changes noise sequences and breaks determinism within epochs.

Actions:
- Make `FlowRouter` mutable in config or allow updating its config without re-seeding RNG.
- Option A (preferred): add `updateConfig(_:)` method on `FlowRouter` that only updates cfg.
- Option B: reconstruct router but transfer RNG state (expose a `snapshotRNGState()` method).

Definition of done:
- Same seed and same inputs yield identical step events even after parameter updates.

### 4) Minimal tests for learning responsiveness
**Why:** ensure learnable parameters actually change outputs.

Actions:
- Add a small deterministic integration test in `Tests/EnergeticCoreTests/FlowLearningIntegrationTests.swift`:
  - Run 1–2 epochs with fixed seed.
  - Assert `params.gains` and/or `lifThreshold` change from initial.
  - Assert output histogram changes when gains are applied.
- Keep tests headless and fast (small bin count, small T).

Definition of done:
- Tests pass and demonstrate parameter influence.

### 5) CLI learning output sanity
**Why:** CLI is the primary user path for headless learning.

Actions:
- Ensure `energetic-cli learn` prints key metrics and final params (already mostly done).
- Add log line that explicitly confirms gains are applied and spikeKick is active.

Definition of done:
- CLI output indicates learning is affecting simulation.

## Minimal config additions/adjustments (if needed)
- `router.flow.dynamics.spike_kick: 0.5` (new field)
- If defaults are required: ensure ConfigCenter assigns a default or fails fast if missing.

## File touch list (expected)
- `Sources/EnergeticCore/FlowConfig.swift` (or `FlowTypes.swift`) — add spikeKick, optional gains plumbed.
- `Sources/EnergeticCore/FlowRouter.swift` — use spikeKick and gains in projection.
- `Sources/EnergeticCore/FlowProjector.swift` — apply gains.
- `Sources/EnergeticCore/FlowLearningLoop.swift` — pass gains into router/projection; preserve RNG.
- `Sources/SharedInfrastructure/ConfigCenter.swift` — add/validate spike_kick config.
- `Configs/baseline.yaml` — add `spike_kick` value.
- `Tests/EnergeticCoreTests/FlowLearningIntegrationTests.swift` — add minimal learning responsiveness test.

## Risks and mitigations
- **Overfitting or instability**: keep learning rates small; clamp bounds.
- **Determinism regressions**: lock RNG state updates; avoid re-seeding mid-epoch.
- **Silent no-op learning**: add a test that fails if gains/spikeKick don’t change outputs.

## Acceptance criteria (MVP)
- `energetic-cli learn` changes parameters and affects histogram output.
- Gains and spikeKick are used in simulation.
- Deterministic runs remain deterministic given the same seed and config.
- All tests still headless and green.

