# Flow Learning Visualization Plan (v0)

Status: proposed
Owner: EnergeticUI
Scope: visualize learning progress (metrics + parameters + bins) alongside existing flow pipeline visualization.

## Goals (v0)
- Show learning metrics over epochs (total loss, bin loss, spike loss, boundary loss).
- Show current parameters (lif threshold, radial bias, spike kick, gain stats).
- Show output histogram and target histogram (bins) to see convergence.
- Work in headless-safe mode (no UI required for CLI/tests).
- Use existing logging/snapshot infrastructure; no new CLI flags.

## Non-goals (v0)
- No GPU visualization of gradients.
- No interactive editing of parameters in UI.
- No training data browsing UI.

## Inputs and data sources
1) **Learning metrics** emitted per epoch.
2) **Parameters** (gains + scalars).
3) **Histogram**: output bins vs target bins (if available).

Primary pipeline:
- Learning loop emits **LearningMetrics** per epoch.
- LoggingHub publishes `trainer.loop` events.
- PipelineSnapshot can include learning section for UI/headless snapshots.

## Data model updates

### A) Logging events (low-cost, immediate)
- Extend `trainer.loop` payload to include:
  - epoch
  - totalLoss, binLoss, spikeLoss, boundaryLoss
  - spikeRate, completionRate, meanRadialMiss
  - params: lifThreshold, radialBias, spikeKick, gainMean, gainVariance
  - binsSummary: nonzeroBins, yHatStats (mean/var/min/max)
- Keep payload concise and flat for easy decoding in UI.

### B) Snapshot schema (optional for v0.1)
- Extend `PipelineSnapshot` (flow section) with:
  - learningMetrics: latest epoch stats
  - gainsSummary (mean/var/min/max) and optionally top-k gains
  - bins: output histogram and targets (if target source is deterministic)
- Keep snapshots bounded size (top-k / sampling; no full per-epoch history).

## UI plan

### View: Learning Overview Panel
Placement: side panel or overlay in EnergeticUI.

Elements (top to bottom):
1) **Epoch & Status**
   - Epoch number, “learning enabled” indicator.
2) **Loss charts** (line graphs)
   - Total loss
   - Bin loss
   - Spike loss
   - Boundary loss
   (Use shared x-axis; show last N epochs, e.g. 200)
3) **Spike / Completion**
   - Spike rate (line)
   - Completion rate (line)
   - Mean radial miss (line)
4) **Parameters**
   - LIF threshold
   - Radial bias
   - Spike kick
   - Gain mean/variance
5) **Histogram**
   - Two overlaid bars: output bins vs target bins
   - Optional smoothing; show top-k bins if B is large

### Interaction
- Toggle panel on/off.
- Pause UI updates (if running heavy training) to reduce overhead.

## Implementation steps

### Step 1: Log richer trainer.loop payload (core)
- Update `FlowLearningLoop` to emit a structured log message after each epoch.
- Use `LoggingHub.emit(process: "trainer.loop", level: .info, message: ...)` with JSON string or key=value format.
- Decide on a consistent format; prefer JSON for easy decode.

### Step 2: UI parsing
- In EnergeticUI, add a small parser to interpret trainer.loop log payloads.
- Maintain in-memory ring buffers for metrics (last N epochs).

### Step 3: Learning panel UI (SwiftUI)
- Add a `LearningView` to show charts and stats.
- Use existing UI layout style; keep CPU overhead low.

### Step 4: Histograms
- Use existing histogram components (if any) or add a lightweight bar chart view.
- Plot output bins (yHat) vs target bins.
- If bins are huge, show top-k or downsample.

### Step 5: Snapshot (optional v0.1)
- Extend `PipelineSnapshot` JSON to include latest learning summary.
- UI can optionally read from snapshot on startup for warm state.

## Files to touch (expected)
- `Sources/EnergeticCore/FlowLearningLoop.swift` (emit structured log per epoch)
- `Sources/SharedInfrastructure/LoggingHub.swift` (if helpers needed)
- `Sources/SharedInfrastructure/PipelineSnapshot.swift` or `PipelineSnapshot+Flow.swift` (optional v0.1)
- `Sources/EnergeticUI/*` (new LearningView, state models, log parser)
- `Sources/EnergeticVisualizationDemo/*` (if demo panel integration needed)

## Metrics payload spec (suggested JSON)
```json
{
  "epoch": 12,
  "loss": {"total": 1.234, "bins": 0.98, "spike": 0.12, "boundary": 0.13},
  "rates": {"spike": 0.18, "completion": 0.91},
  "radius": {"mean_miss": 0.04},
  "params": {"lif": 0.83, "radial_bias": 0.22, "spike_kick": 0.62, "gain_mean": 1.12, "gain_var": 0.08},
  "bins": {"nonzero": 154, "mean": 0.92, "var": 0.11, "min": 0.0, "max": 3.2}
}
```

## Acceptance criteria (v0)
- UI shows live curves for loss + spike/completion metrics.
- Parameters update visually per epoch.
- Histogram view shows output vs target (or at least output + summary).
- No impact on headless/CLI; learning still runs without UI.

## Risks / notes
- Learning may be slower if UI processes too much data — use ring buffers and sample bins.
- For large B, render only top-k bins or downsample to 128.
- Logging payload should stay small to avoid log I/O bottlenecks.

