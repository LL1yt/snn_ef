# Session Summary — 2025-11-04 (FlowRouter migration)

Status: Flow backend landed (no fallbacks). Grid/CSR router deprecated and removed from build.

What we changed

- Config schema (router)
  - Introduced router.backend = "flow" and router.flow {...}; validated in SharedInfrastructure/ConfigCenter.swift.
  - Kept energy_constraints.energy_base invariant (== capsule.base; bins = base).
  - Updated Docs/config_center_schema.md and Configs/baseline.yaml.

- EnergeticCore (new Flow backend)
  - Added: FlowTypes.swift (FlowConfig/LIF/Dynamics, FlowParticle/FlowState, RNG).
  - Added: FlowSeeds.swift (ring seeds), FlowProjector.swift (circle projection), FlowRouter.swift (LIF + drift + noise + clamped speed), FlowBridgeSNN.swift.
  - Tests: FlowTypesTests, FlowSeedsTests, FlowProjectorTests, FlowRouterTests, FlowBridgeSNNSmokeTests.

- CLI integration
  - EnergeticCLI now runs capsule example → energies → FlowRouter → prints summary and hint.
  - Linked CapsuleCore into EnergeticCLI target.
  - Restored compatibility line for tests: prints `Router backend: flow`.

- Removal/disable of legacy grid
  - Excluded and stubbed: TemporalGrid (Graph.swift), SpikeRouter.swift, EnergyFlowSimulator.swift, GraphBuilder.swift.
  - Excluded legacy tests in Package.swift.
  - EnergeticUI ViewModel switched to headless (no simulator) with an explicit message; demo uses stub RouterConfig.

- Docs and WARP
  - Created Docs/migration_to_flow_router.md (plan earlier in session).
  - Marked grid docs as DEPRECATED and pointed to FlowRouter plan.
  - Updated WARP.md to reflect FlowRouter architecture and invariants.

Why this matters

- Single backend (FlowRouter) simplifies config, code, and tests; removes grid/CSR complexity and softmax routing path.
- Continuous dynamics + circular projection align with capsule base B and enable emergent, organic behavior.

Next steps

1) Flow UI and snapshots
- Implement Flow snapshot export (bins + selected particle samples) into PipelineSnapshot.
- Minimal SwiftUI view to visualize ring seeds and boundary histogram; keep headless parity.

2) Capsule ↔ Flow integration polish
- Add quantization/recovery hooks from float bins back to digits (round/clamp) with CRC retries (optional small beam search).

3) Stability and guards
- Add NaN/Inf guards, bounds asserts, and optional bin smoothing (cosine) in FlowProjector.
- Deterministic seeding across runs; surface seed in hint/log.

4) Performance
- SoA arrays and SIMD passes in FlowRouter inner loop; profile with Instruments.
- Prototype Metal kernel for step update + binning; validate parity with CPU.

5) Testing
- Expand tests: determinism by seed, projection wrap, energy floor behavior, regression tests on sample seeds.
- Update CLIntegrationTests as needed for additional assertions (e.g., bins summary).

6) Docs/readme
- Short README section for FlowRouter usage (CLI + expected fields), and a migration note for contributors.

7) Optional: interactions
- Add simple repulsion/attraction toggle (shared potential), preserving determinism via seeded RNG.

Checklist to close this migration
- [ ] Flow snapshot in PipelineSnapshot + test
- [ ] Minimal Flow UI view + headless parity confirmed
- [ ] EnergeticCLI demo subcommand to dump bins as JSON
- [ ] Performance smoke benchmark (time per step for N seeds)
- [ ] Docs: README excerpt and updated diagrams
