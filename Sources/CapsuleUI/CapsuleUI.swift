import SwiftUI
import CapsuleCore
import SharedInfrastructure

public struct CapsuleUIPreview: View {
    private let capsule = CapsulePlaceholder()

    public init() {}

    public var body: some View {
        VStack {
            Text("Capsule UI Placeholder")
            Text(capsule.describe())
                .font(.caption)
        }
        .padding()
    }
}
