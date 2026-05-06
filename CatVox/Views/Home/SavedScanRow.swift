import SwiftUI

struct SavedScanRow: View {
    let scan: SavedScan
    let openAccessibilityIdentifier: String
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    thumbnail

                    VStack(alignment: .leading, spacing: 6) {
                        Text(scan.persona.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(scan.primaryEmotion)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)

                        Text("“\(scan.catThought)”")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(openAccessibilityIdentifier)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(openAccessibilityIdentifier).deleteButton")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = UIImage(contentsOfFile: ScanHistoryStore.thumbnailURL(for: scan).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "video")
                        .foregroundStyle(.white.opacity(0.28))
                }
        }
    }
}
