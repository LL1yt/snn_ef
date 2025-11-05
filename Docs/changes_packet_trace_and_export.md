# Packet Tracing, Spike Statistics, and Headless Export Implementation

**Date:** 2025-11-02
**Branch:** claude/implement-docs-ui-011CUjmSiLMLXzzSKTkcGxkG

## Summary

Implemented three major features for the EnergeticRouter visualization and analysis:

1. **Packet Tracing** - Complete history tracking for energy packet flow through the network
2. **Spike Statistics** - Comprehensive spike activity monitoring and visualization
3. **Headless Export** - JSON snapshot export for CLI and testing

## Changes

### 1. Packet Tracing

#### EnergyFlowState.swift
- Added `PacketTraceEvent` - single step event (layer, node, energy, membrane, spike)
- Added `PacketTrace` - complete trace history per stream with utilities
- Added `packetTraces: [Int: PacketTrace]` field to `EnergyFlowFrame`

#### SpikeRouter.swift
- Added `routeDetailed()` method returning `RouteStepResult`
- `RouteStepResult` includes spike information, reached output, and died flags

#### EnergyFlowSimulator.swift
- Added trace event collection (`traceEvents: [Int: [PacketTraceEvent]]`)
- Modified `step()` to use `routeDetailed()` and record trace events
- Updated `snapshot()` to build `PacketTrace` objects

### 2. Spike Statistics

#### EnergyFlowState.swift
- Added `SpikeSummary` struct with:
  - Total spike count
  - Spikes per layer
  - Spikes per stream
  - Spike rate calculation
  - Layer and stream activity counters

#### EnergyFlowSimulator.swift
- Added spike tracking fields:
  - `totalSpikeCount: Int`
  - `spikeCountsPerLayer: [Int: Int]`
  - `spikeCountsPerStream: [Int: Int]`
- Updated `step()` to record spike events
- Updated `snapshot()` to generate `SpikeSummary`

#### EnergeticVisualizationView.swift
- Added `spikeSummarySection()` displaying:
  - Total spikes and spike rate
  - Active streams and layers with spikes
  - Per-layer spike distribution
- Added `packetTracesSection()` with:
  - Stream trace summaries (first 5 streams)
  - Start/end positions and energy levels
  - Visual timeline with spike indicators (orange circles)

### 3. Headless Export

#### PipelineSnapshot.swift
- Added `EnergyFlowSnapshot` codable structure with nested types:
  - `PacketSnapshot` - active packet state
  - `LayerSnapshot` - per-layer energy aggregates
  - `TraceEventSnapshot` - trace event data
  - `TraceSnapshot` - complete trace per stream
  - `SpikeSummarySnapshot` - spike statistics
- Added `energyFlowSnapshot` field to `ConfigPipelineSnapshot`
- Added `export(snapshot:energyFlowFrame:)` method

#### EnergyFlowFrameExport.swift (new file)
- Extension `EnergyFlowFrame.toSnapshot()` converting to `EnergyFlowSnapshot`
- Handles all nested conversions (packets, layers, traces, spikes)

#### EnergeticVisualizationViewModel.swift
- Added `exportSnapshot(configSnapshot:)` - exports to default path
- Added `exportSnapshot(to:configSnapshot:)` - exports to custom path
- Added `ExportError` enum for error handling

## Usage

### Viewing Traces in UI

Run `EnergeticVisualizationDemo` to see:
- Spike statistics panel with total counts and rates
- Per-layer spike distribution
- Packet trace timeline for up to 5 streams
- Visual spike indicators in trace timelines

### Exporting Snapshots

```swift
// In UI context with ViewModel
let viewModel = EnergeticVisualizationViewModel(...)
viewModel.runToEnd()

// Export to default pipeline_snapshot path
try viewModel.exportSnapshot(configSnapshot: configSnapshot)

// Export to custom path
try viewModel.exportSnapshot(to: "Artifacts/custom_snapshot.json", configSnapshot: configSnapshot)
```

### CLI/Headless Usage

```swift
let simulator = EnergyFlowSimulator(router: router, initialPackets: packets)
while !simulator.isFinished {
    simulator.step()
}

let frame = simulator.snapshot()
let energySnapshot = frame.toSnapshot()

_ = try PipelineSnapshotExporter.export(
    snapshot: configSnapshot,
    energyFlowFrame: energySnapshot
)
```

## JSON Export Format

The exported JSON includes:

```json
{
  "generatedAt": "2025-11-02T12:00:00Z",
  "profile": "baseline",
  "capsule": { ... },
  "router": { ... },
  "energyFlowSnapshot": {
    "step": 42,
    "timestamp": "2025-11-02T12:00:01Z",
    "gridLayers": 8,
    "gridNodesPerLayer": 16,
    "activePackets": [...],
    "perLayer": [...],
    "traces": [
      {
        "streamID": 0,
        "events": [
          {
            "step": 0,
            "layer": 0,
            "node": 5,
            "energy": 10.5,
            "membrane": 0.3,
            "spike": false
          },
          ...
        ],
        "totalSpikes": 3
      }
    ],
    "spikeSummary": {
      "totalSpikes": 15,
      "spikeRate": 0.125,
      "spikesPerLayer": {"0": 3, "1": 5, ...},
      "spikesPerStream": {"0": 3, "1": 2, ...},
      "layersWithSpikes": 6,
      "activeStreams": 8
    },
    "outputEnergies": {"0": 8.5, "1": 7.2},
    "completedStreams": [0, 1, 2],
    "deadStreams": [],
    "totalActiveEnergy": 45.3
  }
}
```

## Benefits

1. **Debugging** - Full packet path visualization helps identify routing issues
2. **Analysis** - Spike statistics reveal network dynamics and activity patterns
3. **Testing** - Headless export enables automated comparison and validation
4. **Reproducibility** - Complete state snapshots for later analysis

## Future Enhancements

- Timeline chart for spike activity over time
- Heatmap visualization for layer-wise spike density
- Trace comparison between different configurations
- Metal-accelerated trace rendering for large-scale simulations
