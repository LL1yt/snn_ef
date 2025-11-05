import Foundation
import SharedInfrastructure

extension EnergyFlowFrame {
    /// Converts EnergyFlowFrame to EnergyFlowSnapshot for JSON export
    public func toSnapshot() -> ConfigPipelineSnapshot.EnergyFlowSnapshot {
        let packetSnapshots = activePackets.map { packet in
            ConfigPipelineSnapshot.EnergyFlowSnapshot.PacketSnapshot(
                streamID: packet.streamID,
                layer: packet.x,
                node: packet.y,
                energy: Double(packet.energy),
                time: packet.time,
                membrane: Double(packet.membrane)
            )
        }

        let layerSnapshots = perLayer.map { layer in
            ConfigPipelineSnapshot.EnergyFlowSnapshot.LayerSnapshot(
                layer: layer.layer,
                packetCount: layer.packetCount,
                totalEnergy: Double(layer.totalEnergy),
                averageEnergy: Double(layer.averageEnergy)
            )
        }

        let traceSnapshots = packetTraces.values.map { trace in
            let eventSnapshots = trace.events.map { event in
                ConfigPipelineSnapshot.EnergyFlowSnapshot.TraceEventSnapshot(
                    step: event.step,
                    layer: event.layer,
                    node: event.node,
                    energy: Double(event.energy),
                    membrane: Double(event.membrane),
                    spike: event.spike
                )
            }
            return ConfigPipelineSnapshot.EnergyFlowSnapshot.TraceSnapshot(
                streamID: trace.streamID,
                events: eventSnapshots,
                totalSpikes: trace.totalSpikes
            )
        }

        let spikeSummarySnapshot: ConfigPipelineSnapshot.EnergyFlowSnapshot.SpikeSummarySnapshot?
        if let summary = spikeSummary {
            spikeSummarySnapshot = ConfigPipelineSnapshot.EnergyFlowSnapshot.SpikeSummarySnapshot(
                totalSpikes: summary.totalSpikes,
                spikeRate: Double(summary.spikeRate),
                spikesPerLayer: summary.spikesPerLayer,
                spikesPerStream: summary.spikesPerStream,
                layersWithSpikes: summary.layersWithSpikes,
                activeStreams: summary.activeStreams
            )
        } else {
            spikeSummarySnapshot = nil
        }

        let outputEnergiesDouble = outputEnergies.mapValues { Double($0) }

        let isoFormatter = ISO8601DateFormatter()
        let timestampString = isoFormatter.string(from: timestamp)

        return ConfigPipelineSnapshot.EnergyFlowSnapshot(
            step: step,
            timestamp: timestampString,
            gridLayers: grid.layers,
            gridNodesPerLayer: grid.nodesPerLayer,
            activePackets: packetSnapshots,
            perLayer: layerSnapshots,
            outputEnergies: outputEnergiesDouble,
            completedStreams: Array(completedStreams).sorted(),
            deadStreams: Array(deadStreams).sorted(),
            totalActiveEnergy: Double(totalActiveEnergy),
            traces: traceSnapshots.sorted { $0.streamID < $1.streamID },
            spikeSummary: spikeSummarySnapshot
        )
    }
}
