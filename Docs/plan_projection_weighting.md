Title: Projected bins with radial weighting (UI sequence + buffer)

Goal
Provide a deterministic per-particle bin sequence (no -1) and a weighted
histogram contribution for particles that did not reach the boundary, using
projection of the last known point onto the outer circle and a radial weight.

Constraints
- No fallback to zeros for missing bins.
- Weight rule: w = r / R with the same penalty for r > R.
- Must handle multiple particles landing in the same bin (buffered add).
- Must not change training loss by default (UI-only payload).

Definitions
- R: flow radius (config).
- r: last particle radius.
- theta: atan2(y, x).
- bin: FlowProjector.binIndex(theta, bins).
- weight: 
  - if r <= R: w = r / R
  - if r > R: w = R / r  (symmetric penalty)
  - clamp to (0, 1].

Data to capture
- lastPosByID: [Int: SIMD2<Float>] (or array indexed by id).
- lastRadiusByID: [Float] (optional, derived from pos).
- predictedBins: [Int] (one per seed id, no -1).
- projectedHistogram: [Float] (size = bins), sum of weights per bin.

Algorithm (slow path, UI log only)
1) Initialize lastPosByID with seed positions (so every id has a value).
2) During step loop (router.stepWithEvents):
   - For each event, update lastPosByID[event.id] = event.pos.
3) After the loop:
   - For each particle id:
     - pos = lastPosByID[id]
     - r = length(pos)
     - theta = atan2(pos.y, pos.x)
     - bin = FlowProjector.binIndex(theta, bins)
     - predictedBins[id] = bin
     - weight = r <= R ? r / R : R / r
     - projectedHistogram[bin] += weight
4) For particles that completed, optionally force weight = 1.0 to preserve
   "fully reached" contribution (confirm if desired).

Buffering rule
- projectedHistogram is the buffer. Multiple particles add to the same bin.
- Use Float accumulation; no normalization in the buffer step.

UI / Logging changes
- Extend LearningLogPayload (UI log JSON) with:
  - predictedBins: [Int]  (already present)
  - projectedHistogram: [Float]?  (new, optional)
- LearningMetricsView:
  - Use predictedBins for capsule decode sequence.
  - Optionally render projectedHistogram as an extra overlay or toggle.

Files to change
- Sources/EnergeticCore/FlowLearningLoop.swift
  - Track lastPosByID in slow path.
  - Build predictedBins without -1.
  - Build projectedHistogram buffer and attach to UI payload.
- Sources/EnergeticUI/LearningMetricsView.swift
  - Extend LearningLogPayload decode to include projectedHistogram.
  - (Optional) render projectedHistogram as separate series.

Edge cases
- r == 0: weight = 0.
- r very close to 0: avoid NaN; clamp to 0.
- r extremely large: weight ~ 0 (still valid).
- bins mismatch: guard yHat.count == bins for overlay.

Validation
1) Compare predictedBins count vs seed count (must be equal).
2) Verify no -1 in predictedBins.
3) Check projectedHistogram sum increases with more particles.
4) Visual sanity: bins near boundary show higher weight.
5) Capsule decode should stop failing as often when projected bins are used.
