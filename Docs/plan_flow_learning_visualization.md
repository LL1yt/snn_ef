# Flow Learning Visualization Plan (v0)

Status: proposed
Owner: EnergeticUI
Scope: visualize learning progress (metrics + parameters + bins) alongside existing flow pipeline visualization.

## Goals (v0)
- Show learning metrics over epochs (total loss, bin loss, spike loss, boundary loss).
- Show current parameters (lif threshold, radial bias, spike kick, gain stats).
- Show output histogram and target histogram (bins) to see convergence.
- Make the layout wide-first: prioritize horizontal space over vertical stacking.
- Explain the math dynamics on a few tracked streams step-by-step (no circle rendering).
- Allow epoch-by-epoch scrubbing (manual step-through).
- Provide a physics-friendly view: show actual trajectory, boundary, and spike jumps visually.
- Work in headless-safe mode (no UI required for CLI/tests).
- Use existing logging/snapshot infrastructure; no new CLI flags.
    - Boundary rendered as a sector arc (not full circle).
    - Grid rendered as dot lattice.
    - Encodings via color, thickness, vector direction, line style; include a legend.

## Non-goals (v0)
- No GPU visualization of gradients.
- No interactive editing of parameters in UI.
- No training data browsing UI.

## Inputs and data sources
1) **Learning metrics** emitted per epoch.
2) **Parameters** (gains + scalars).
3) **Histogram**: output bins vs target bins (if available).
4) **Tracked dynamics** for 3 streams (per-step r, θ, E, V, spike, speed).
5) **Trajectory points** for 3 streams (x,y per step) to render a path and spike jumps.

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
  - traces: up to 3 tracked streams with per-step dynamics
  - path: per-step positions for 3 tracked streams (x,y), spike flag, projected bin
- Keep payload concise and flat for easy decoding in UI.

### B) Snapshot schema (optional for v0.1)
- Extend `PipelineSnapshot` (flow section) with:
  - learningMetrics: latest epoch stats
  - gainsSummary (mean/var/min/max) and optionally top-k gains
  - bins: output histogram and targets (if target source is deterministic)
- Keep snapshots bounded size (top-k / sampling; no full per-epoch history).

## UI plan

### View: Learning Overview Panel (wide layout)
Placement: wide panel (primary content), minimal vertical stacking.

Layout (2 rows, no horizontal scroll):
Row 1 (wide):
- **Trajectory** (≈60% width)
- **Histogram** (≈40% width)

Row 2 (compact):
- **Metrics card**: loss + rates sparklines
- **Parameters card**
- **Dynamics card**: 3 stream columns + step table (last 10 steps)

Trajectory specifics:
- boundary as sector arc + dot grid background
- spikes as sharp jump segments (highlighted color + thicker stroke)
- if particle didn't reach boundary: dashed projection line to boundary
- vector arrowheads for direction (last segment)
- current step marker and step number
- legend in corner: color/line/width meanings
- optional **visual snap-to-grid** (UI-only) for points/segments

No circle/ring rendering in this panel.

### Interaction
- Toggle panel on/off.
- Pause UI updates (if running heavy training) to reduce overhead.
- Epoch scrubber (slider) to browse epochs; manual prev/next buttons.
- Window resizable; UI scales horizontally, fixed row heights.
- Visual snap-to-grid toggle (UI only, no effect on simulation).

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

### Step 5: Dynamics traces (new)
- In `FlowLearningLoop`, track up to 3 stream IDs (e.g., first 3 seeds).
- For each step, record compact dynamics:
  - t (step), r, theta, energy, V, spiked, bin, speed, radialSpeed
- Emit these in `trainer.loop` payload as `traces`.

### Step 6: Trajectory traces (new)
- Record 2D position per step for the same tracked streams.
- Add optional projection info (if r < R at end of epoch) for dashed line to boundary.
- Emit as `paths` array with (t, x, y, spiked, projectedBin, speed, radialSpeed).

### Step 7: Wide layout panel (new)
- Replace vertical stack with `HStack` layout:
  - left charts (compact grid)
  - center histogram
  - right dynamics traces
- add trajectory column with 2D path view and boundary/grid.
- add epoch scrubber (slider + prev/next).
- Use fixed heights and flexible widths to avoid vertical overflow.
 - Reflow into 2 rows (Trajectory + Histogram on top; Metrics/Params/Dynamics on bottom).

### Step 8: Snapshot (optional v0.1)
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
  "bins": {"nonzero": 154, "mean": 0.92, "var": 0.11, "min": 0.0, "max": 3.2},
  "traces": [
    {"id": 0, "steps": [{"t": 0, "r": 0.9, "theta": 0.1, "E": 12.0, "V": 0.2, "spike": false, "bin": null, "speed": 0.2, "radial_speed": 0.1}]}
  ],
  "paths": [
    {"id": 0, "points": [{"t": 0, "x": 0.8, "y": 0.1, "spike": false, "bin": null, "speed": 0.2, "radial_speed": 0.1}]}
  ]
}
```

## Acceptance criteria (v0)
- UI shows live curves for loss + spike/completion metrics.
- Parameters update visually per epoch.
- Histogram view shows output vs target (or at least output + summary).
- Per-step dynamics for 3 streams visible and readable (no circles).
- Trajectory view shows path, boundary, spike jumps, and projection to boundary.
- Epoch scrubber allows reviewing previous epochs without restarting.
- Layout stays within window height at default sizes.
- No impact on headless/CLI; learning still runs without UI.

## Risks / notes
- Learning may be slower if UI processes too much data — use ring buffers and sample bins.
- For large B, render only top-k bins or downsample to 128.
- Logging payload should stay small to avoid log I/O bottlenecks.
- Traces must be compact: cap steps to `steps_per_epoch` and max streams = 3.
- Trajectory rendering should be lightweight: use Canvas and decimate points if needed.
- Legend must remain minimal; prefer 4–6 symbols max.
- Visual snap-to-grid is UI-only (no changes to simulation).
