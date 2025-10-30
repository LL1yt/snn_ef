import SwiftUI
import CapsuleCore
import SharedInfrastructure

/// Main interactive pipeline visualization view
public struct CapsulePipelineView: View {
    @StateObject private var viewModel: PipelineViewModel
    @State private var inputText: String
    @State private var currentStageIndex: Int = 0
    @State private var isPlaying: Bool = false
    @State private var expandedStages: Set<UUID> = []
    @State private var playTimer: Timer?

    public init(config: ConfigRoot.Capsule) {
        _viewModel = StateObject(wrappedValue: PipelineViewModel(config: config))
        _inputText = State(initialValue: config.pipelineExampleText)
    }

    public var body: some View {
        NavigationSplitView {
            // Sidebar: controls and metrics
            sidebarContent
                .frame(minWidth: 320, idealWidth: 360)
        } detail: {
            // Main area: stage visualization
            detailContent
        }
        .navigationTitle("Capsule Pipeline Visualizer")
        .onDisappear {
            stopAutoPlay()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Input section
                inputSection

                // Navigation controls
                if viewModel.snapshot != nil {
                    navigationSection
                }

                // Metrics panel
                if let snapshot = viewModel.snapshot {
                    MetricsPanelView(snapshot: snapshot)
                }

                Spacer()
            }
            .padding()
        }
    }

    @ViewBuilder
    private var inputSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Input Text")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                TextEditor(text: $inputText)
                    .font(.body)
                    .frame(height: 120)
                    .border(Color.gray.opacity(0.2), width: 1)
                    .disabled(viewModel.isExecuting)

                HStack {
                    Button {
                        Task {
                            await executeRoundtrip()
                        }
                    } label: {
                        if viewModel.isExecuting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                            Text("Executing...")
                        } else {
                            Image(systemName: "play.circle.fill")
                            Text("Execute Pipeline")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isExecuting || inputText.isEmpty)

                    if let error = viewModel.error {
                        Button {
                            viewModel.error = nil
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .help("Dismiss error")
                    }
                }

                if let error = viewModel.error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error.localizedDescription)
                                .font(.footnote)
                                .foregroundColor(.red)
                            if let suggestion = (error as? LocalizedError)?.recoverySuggestion {
                                Text(suggestion)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
        } label: {
            Label("Input", systemImage: "text.cursor")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var navigationSection: some View {
        if let snapshot = viewModel.snapshot {
            StageNavigationView(
                currentIndex: currentStageIndex,
                totalStages: snapshot.stages.count,
                isPlaying: isPlaying,
                onPrevious: {
                    currentStageIndex = max(0, currentStageIndex - 1)
                },
                onNext: {
                    currentStageIndex = min(snapshot.stages.count - 1, currentStageIndex + 1)
                },
                onTogglePlay: {
                    if isPlaying {
                        stopAutoPlay()
                    } else {
                        startAutoPlay()
                    }
                },
                onReset: {
                    currentStageIndex = 0
                    stopAutoPlay()
                }
            )
        }
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        if let snapshot = viewModel.snapshot {
            pipelineStagesView(snapshot: snapshot)
        } else if viewModel.isExecuting {
            executingView
        } else {
            emptyStateView
        }
    }

    @ViewBuilder
    private func pipelineStagesView(snapshot: PipelineSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(snapshot.stages.enumerated()), id: \.element.id) { idx, stage in
                        stageCard(
                            stage: stage,
                            index: idx,
                            snapshot: snapshot,
                            isCurrent: idx == currentStageIndex,
                            isExpanded: expandedStages.contains(stage.id)
                        )
                        .id(stage.id)
                    }
                }
                .padding()
            }
            .onChange(of: currentStageIndex) { _, newIndex in
                if newIndex < snapshot.stages.count {
                    withAnimation {
                        proxy.scrollTo(snapshot.stages[newIndex].id, anchor: .top)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stageCard(
        stage: PipelineStage,
        index: Int,
        snapshot: PipelineSnapshot,
        isCurrent: Bool,
        isExpanded: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            StageHeaderView(
                stage: stage,
                expanded: isExpanded
            ) {
                withAnimation {
                    if isExpanded {
                        expandedStages.remove(stage.id)
                    } else {
                        expandedStages.insert(stage.id)
                    }
                }
            }
            .onTapGesture {
                currentStageIndex = index
            }

            // Detail content
            if isExpanded || isCurrent {
                stageDetailView(for: stage, snapshot: snapshot)
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(isCurrent ? VisualizationColorScheme.highlightBackground : Color.clear)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? Color.blue : Color.clear, lineWidth: 2)
        )
        .shadow(color: isCurrent ? Color.blue.opacity(0.2) : Color.clear, radius: 8)
    }

    @ViewBuilder
    private func stageDetailView(for stage: PipelineStage, snapshot: PipelineSnapshot) -> some View {
        switch stage.type {
        case .input:
            InputStageView(stage: stage)

        case .blockStructure:
            BlockStructureView(stage: stage)

        case .prpTransform:
            if let blockStage = snapshot.stage(ofType: .blockStructure),
               case let .header(header, payload, _) = blockStage.data {
                // Reconstruct pre-PRP bytes using original header metadata
                let beforeBytes: [UInt8] = {
                    var bytes = [UInt8](repeating: 0, count: snapshot.config.blockSize)
                    let headerBytes = header.encode()
                    if headerBytes.count == CapsuleHeader.byteCount {
                        bytes.replaceSubrange(0..<CapsuleHeader.byteCount, with: headerBytes)
                    }

                    let payloadEnd = CapsuleHeader.byteCount + payload.count
                    if payloadEnd <= bytes.count {
                        bytes.replaceSubrange(CapsuleHeader.byteCount..<payloadEnd, with: payload)
                    }

                    return bytes
                }()
                PRPStageView(stage: stage, beforeBytes: beforeBytes)
            } else {
                Text("PRP stage data unavailable")
                    .foregroundColor(.secondary)
            }

        case .capsuleBlock:
            CapsuleBlockView(stage: stage)

        case .baseConversion:
            DigitsStageView(stage: stage, config: snapshot.config)

        case .printableString:
            PrintableStageView(stage: stage, config: snapshot.config)

        case .energiesMapping:
            EnergiesStageView(stage: stage, config: snapshot.config)

        case .normalization:
            NormalizedStageView(stage: stage, config: snapshot.config)

        case .reverseProcess:
            ReverseStageView(stage: stage)

        case .recovered:
            RecoveredStageView(stage: stage, originalText: snapshot.inputText)
        }
    }

    @ViewBuilder
    private var executingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Executing Pipeline...")
                .font(.headline)
            Text("Processing stages...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Enter text and execute pipeline")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("The visualization will show all transformation stages")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions

    private func executeRoundtrip() async {
        stopAutoPlay()
        currentStageIndex = 0
        expandedStages.removeAll()
        await viewModel.executeRoundtrip(inputText)
    }

    private func startAutoPlay() {
        isPlaying = true
        playTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak viewModel] _ in
            Task { @MainActor in
                guard let viewModel, let snapshot = viewModel.snapshot else {
                    stopAutoPlay()
                    return
                }

                if currentStageIndex < snapshot.stages.count - 1 {
                    currentStageIndex += 1
                } else {
                    stopAutoPlay()
                }
            }
        }
    }

    private func stopAutoPlay() {
        isPlaying = false
        playTimer?.invalidate()
        playTimer = nil
    }
}

// MARK: - ViewModel

@MainActor
public class PipelineViewModel: ObservableObject {
    @Published public var snapshot: PipelineSnapshot?
    @Published public var isExecuting: Bool = false
    @Published public var error: Error?

    private let config: ConfigRoot.Capsule
    private let executor: PipelineExecutor

    public init(config: ConfigRoot.Capsule) {
        self.config = config
        self.executor = PipelineExecutor(config: config)
    }

    public func executeRoundtrip(_ input: String) async {
        isExecuting = true
        error = nil

        do {
            let result = try await executor.executeRoundtrip(input)
            snapshot = result

            LoggingHub.emit(
                process: "ui.pipeline",
                level: .info,
                message: "Pipeline executed: \(result.stages.count) stages, \(DataFormatter.formatDuration(result.totalDuration))"
            )
        } catch {
            self.error = error
            LoggingHub.emit(
                process: "ui.pipeline",
                level: .error,
                message: "Pipeline failed: \(error.localizedDescription)"
            )
        }

        isExecuting = false
    }
}
