import SwiftUI
import EnergeticCore
import SharedInfrastructure

public struct EnergeticUIPreview: View {
    private let router = EnergeticRouterPlaceholder()

    public init() {}

    public var body: some View {
        VStack {
            Text("Energetic Router UI Placeholder")
            Text(router.describe())
                .font(.caption)
        }
        .padding()
    }
}
