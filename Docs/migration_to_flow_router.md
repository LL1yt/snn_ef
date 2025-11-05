# Migration Plan: Continuous Flow Router (Circle Boundary)

Status: proposal for immediate execution (no fallbacks)
Owner: EnergeticCore

1) Decision: Circle vs Square
- Choose circle. Rationale: uniform angular parameterization → direct θ→bin mapping for exactly B bins; rotational invariance; smooth projection (no corner artifacts as with square perimeter parametrization).

2) Scope and invariants
- Replace discrete temporal grid router with continuous 2D flow router (FlowRouter).
- Input: energies from Capsule (length D), seeds placed on inner ring; simulate T steps in R².
- Output: boundary projector on circle radius R → angular histogram with exactly B bins, where B == capsule.base (Config invariant preserved).
- Headless-first; fail fast on config/schema violations; centralized logging/process_id unchanged in principle.

3) Configuration schema changes (breaking)
- Remove router.layers, router.nodes_per_layer, router.snn.delta_* tied to grid.
- Introduce router.backend = "flow" and router.flow section.
- Keep router.energy_constraints.energy_base (must equal capsule.base).

New YAML (router section):
```yaml
router:
  backend: "flow"              # required; only "flow" supported after migration
  flow:
    T: 12                       # time steps
    radius: 10.0                # boundary R
    seed_layout: "ring"         # ring | disk
    seed_radius: 1.0            # r0 for ring layout
    lif:
      decay: 0.92               # 0<decay<1
      threshold: 0.8            # (0,1]
      reset_value: 0.0
      surrogate: "fast_sigmoid" # from existing enum
    dynamics:
      radial_bias: 0.15         # outward drift strength
      noise_std_pos: 0.01       # positional noise per step
      noise_std_dir: 0.05       # direction jitter
      max_speed: 1.0            # clamp for stability
      energy_alpha: 0.9         # decay of energy per step (replaces router.alpha)
      energy_floor: 1.0e-5      # drop threshold (kept)
    interactions:
      enabled: false            # v2; optional
      type: "none"              # none|repel|attract|kernel
      strength: 0.0
    projection:
      shape: "circle"           # fixed to circle in this plan
      bins: 256                 # must equal energy_constraints.energy_base
      bin_smoothing: 0.0        # optional cosine smoothing
  energy_constraints:
    energy_base: 256            # must equal capsule.base
```
Validation deltas in ConfigCenter:
- Ensure router.backend == "flow".
- router.flow.projection.bins == router.energy_constraints.energy_base == capsule.base.
- lif.decay∈(0,1), lif.threshold∈(0,1], dynamics.energy_alpha∈(0,1], energy_floor≥0, radius>0, T≥1, max_speed>0.

4) Code migrations (delete/replace)
Remove (hard-delete, no stubs):
- Sources/EnergeticCore/Graph.swift (TemporalGrid)
- Sources/EnergeticCore/GraphBuilder.swift (RouterFactory grid)
- Sources/EnergeticCore/GraphTypes.swift (RouterConfig with layers/nodes_per_layer; EnergyPacket with int x/y)
- Sources/EnergeticCore/SpikeRouter.swift (grid routing)
- Sources/EnergeticCore/EnergyFlowSimulator.swift (grid-step simulator)
- Tests/EnergeticCoreTests/*Graph*Tests.swift
- Tests/EnergeticCoreTests/SpikeRouterTests.swift
- Tests/EnergeticCoreTests/EnergyFlowSimulatorTests.swift

Retain/reuse:
- Sources/EnergeticCore/SurrogateActivation.swift (unchanged)
- CapsuleCore/*, SharedInfrastructure/*, EnergeticCLI scaffolding

Add (new files):
- Sources/EnergeticCore/FlowTypes.swift
  - FlowConfig (decoded from ConfigRoot.RouterFlow)
  - FlowParticle { id, pos: SIMD2<Float>, vel: SIMD2<Float>, energy: Float, V: Float }
  - FlowState { particles[], step, rng }
- Sources/EnergeticCore/FlowRouter.swift
  - step(state) -> state: LIF update (V = decay*V + drive + noise; if V>threshold → spike: vel += jump(dir); V=reset)
  - drift: vel += radial_bias * normalize(pos)
  - clamp speed, apply energy_alpha, drop if energy<floor
- Sources/EnergeticCore/FlowSeeds.swift
  - ring layout: θ_i = 2π·i/D, pos_i = r0·[cosθ, sinθ], energy from input E[i]
- Sources/EnergeticCore/FlowProjector.swift
  - project when ||pos||≥R or on step=T: θ = atan2(y,x), bin = floor((θ mod 2π)/2π * B)
  - accumulate energy per bin (with optional smoothing)
- Sources/EnergeticCore/FlowBridgeSNN.swift
  - makeEnergies(from capsule) → seeds → simulate → boundary bins → vector length B (1..B after quantization if needed)
- Sources/SharedInfrastructure/PipelineSnapshot+Flow.swift
  - new Flow snapshot model (no grid); export particle samples, per-bin histogram, spike stats
- EnergeticUI: minimal adapter to render particles (optional in later step)

5) ConfigCenter model updates
- Modify Sources/SharedInfrastructure/ConfigCenter.swift:
  - Replace ConfigRoot.Router with:
    - backend: String
    - flow: RouterFlow (new nested struct with fields above)
    - energyConstraints
  - Update Validation.ensureRouterParameters() → ensureFlowParameters()
  - Update PipelineSnapshot exporter RouterSummary to flow-oriented fields (T, radius, decay, threshold, energy_alpha, energy_floor, bins)

6) Logging and ProcessRegistry
- Keep existing aliases but rename to flow-specific for clarity:
  - router.flow.step, router.flow.spike, router.flow.output
- Update Docs/config_center_schema.md process_registry accordingly.
- LoggingHub: emit trace per step (counts, spike rate), optional per-particle sample at low rate.

7) Bridge and invariants
- Bins count equals capsule.base; output vector length B with float or int energies depending on phase:
  - v1: Float bins (sum of energies that hit boundary per θ-bin)
  - v1.1: Quantize to integers in [1..B] only at Capsule recovery boundary
- Energy guards: clip NaN/Inf; assert non-negative energies; drop on violations (fail fast if configured).

8) Tests (replace suite)
- FlowTypesTests: seed layout determinism by seed, bounds checks
- FlowRouterTests:
  - LIF dynamics: spike when drive high; V reset
  - Radial drift moves outward; clamp speed respected
  - Energy decay and floor drop
- FlowProjectorTests: angle→bin mapping, wrap-around, smoothing
- BridgeTests: D→simulate→bins length == B, determinism with fixed seed
- ConfigCenterFlowTests: schema validation (backend==flow, invariants)
- SnapshotExportFlowTests: JSON contains flow fields

9) CLI and demos
- EnergeticCLI: replace demo to run FlowBridgeSNN end-to-end; headless report prints: steps, spike_rate, completed_count, bins summary
- CapsulePipelineDemo: integrate new snapshot (optional)

10) UI (optional phase)
- EnergeticUI: new Flow view to draw particle trails; subscribe to LoggingHub (router.flow)
- Toggle rendering rate; headless unaffected

11) Migration order (no fallbacks)
- PR1: Config schema + types (ConfigCenter, schema doc, snapshot exporter – flow-only)
- PR2: Core flow engine (FlowTypes, FlowRouter, FlowSeeds, FlowProjector) + unit tests
- PR3: Bridge (FlowBridgeSNN) + integration tests with Capsule energies; update EnergeticCLI demo
- PR4: Remove old grid code and tests; fix package manifest if needed
- PR5: Snapshot export (flow) and minimal UI adapter (optional)

12) What gets removed vs replaced
- Removed: TemporalGrid, RouterFactory (grid), SpikeRouter, EnergyFlowSimulator, all grid tests/docs
- Replaced: Router config model, PipelineSnapshot router summary, CLI demo
- Reused: SurrogateActivation, SharedInfrastructure, CapsuleCore, LoggingHub, ProcessRegistry

13) Risks and guards
- Divergence/never-exit: enforce outward bias + max T + radius R stop; project last position
- Numerical stability: clamp speed, noise_std, guard NaN/Inf, assert bins==B
- Performance: SoA arrays; SIMD for particle updates; later Metal offload for hot loops

14) Follow-ups (not in MVP)
- Interactions field (repulsion/attraction kernel) for swarm effects
- Trainable seeds and/or learned direction bias
- Metal kernels for LIF update and binning; MPS reductions
- Fourier projection instead of histogram for smoother embeddings

15) File checklist (create/modify/delete)
- Create: FlowTypes.swift, FlowRouter.swift, FlowSeeds.swift, FlowProjector.swift, FlowBridgeSNN.swift, PipelineSnapshot+Flow.swift
- Modify: SharedInfrastructure/ConfigCenter.swift, Docs/config_center_schema.md, SharedInfrastructure/PipelineSnapshot.swift (or split), EnergeticCLIApp.swift
- Delete: Graph.swift, GraphBuilder.swift, GraphTypes.swift, SpikeRouter.swift, EnergyFlowSimulator.swift, their tests

16) Acceptance criteria
- `router.backend == flow` is the only supported backend
- `bins == capsule.base` enforced; output vector length == B
- All new tests green; old grid tests removed
- Headless snapshot JSON contains flow fields and boundary histogram
- CLI demo prints deterministic summary with fixed seed

Appendix: Minimal flow step pseudocode
```swift
struct FlowParticle { var pos, vel: SIMD2<Float>; var E: Float; var V: Float; let id: Int }
func step(p: inout FlowParticle, cfg: FlowConfig, rng: inout RNG) -> Bool {
  // drive from pos, E, time: embed as needed (reuse SpikingKernel if desired)
  let u = inputVector(pos, E, t)
  var V = p.V
  let out = kernel.forward(input: u, membrane: &V) // spike? delta dir?
  p.V = V > cfg.lif.threshold ? cfg.lif.resetValue : V
  let dir = normalize(p.pos) + jitter(rng, cfg.noise_std_dir)
  p.vel += cfg.dynamics.radial_bias * dir + out.deltaXY
  p.vel = clamp(p.vel, max: cfg.dynamics.max_speed)
  p.pos += p.vel
  p.E *= cfg.dynamics.energy_alpha
  return p.E >= cfg.dynamics.energy_floor
}
```
