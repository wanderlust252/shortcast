import SwiftUI

struct ProductSelectionView: View {

    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("Choose the product to focus on")
                    .font(.title2.weight(.semibold))
                if let job = workspace.job {
                    Text("\(job.fileName)  ·  \(job.durationLabel)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                ForEach(workspace.discoveredProducts) { product in
                    Button {
                        workspace.startShortsWithProduct(
                            product,
                            modelManager: modelManager,
                            settings: settings)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: product.label))
                                .font(.title3)
                                .frame(width: 34, height: 34)
                                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(product.displayName)
                                    .font(.headline)
                                Text(product.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int((product.averageConfidence * 100).rounded()))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .frame(maxWidth: 520)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                }
            }

            HStack(spacing: 12) {
                Button {
                    workspace.startShortsWithProduct(nil, modelManager: modelManager, settings: settings)
                } label: {
                    Label("Use normal moment finder", systemImage: "wand.and.stars")
                }
                Button(role: .cancel) {
                    workspace.startOver()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func icon(for label: String) -> String {
        switch label {
        case "handbag", "backpack", "suitcase": "bag"
        case "bottle", "cup", "wine glass": "waterbottle"
        case "cell phone": "iphone"
        case "laptop", "keyboard", "mouse": "laptopcomputer"
        case "book": "book"
        case "vase": "shippingbox"
        default: "cube"
        }
    }
}
