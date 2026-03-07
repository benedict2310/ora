//
//  AttachmentTrayView.swift
//  Ora
//
//  Pending attachment tray for the overlay composer.
//

import SwiftUI

struct AttachmentTrayView: View {
    let attachments: [StagedImageAttachment]
    let reduceTransparency: Bool
    let onRemove: (UUID) -> Void
    let onClearAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(self.headerText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if self.attachments.count > 1 {
                    Button("Clear all") {
                        self.onClearAll()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(self.attachments) { attachment in
                        AttachmentChipView(
                            attachment: attachment,
                            reduceTransparency: self.reduceTransparency,
                            onRemove: {
                                self.onRemove(attachment.id)
                            }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var headerText: String {
        if self.attachments.count == 1 {
            return "1 image attached"
        }
        return "\(self.attachments.count) images attached"
    }
}

private struct AttachmentChipView: View {
    let attachment: StagedImageAttachment
    let reduceTransparency: Bool
    let onRemove: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        HStack(spacing: 8) {
            AttachmentThumbnailView(attachment: self.attachment)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)

                Text(self.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                self.onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove image attachment")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(self.background(shape: shape))
    }

    private var title: String {
        if let originalFilename = self.attachment.originalFilename,
           !originalFilename.isEmpty {
            return originalFilename
        }

        switch self.attachment.source {
        case .clipboard:
            return "Clipboard image"
        case .fileImport:
            return "Image file"
        case .screenshot:
            return "Screenshot"
        }
    }

    private var subtitle: String {
        var components: [String] = []

        if let pixelWidth = self.attachment.pixelWidth,
           let pixelHeight = self.attachment.pixelHeight {
            components.append("\(pixelWidth)x\(pixelHeight)")
        }

        let sizeKB = max(Int(round(Double(self.attachment.byteCount) / 1024.0)), 1)
        components.append("\(sizeKB) KB")

        return components.joined(separator: " • ")
    }

    @ViewBuilder
    private func background(shape: RoundedRectangle) -> some View {
        if self.reduceTransparency {
            shape
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        } else {
            shape
                .glassEffect(.regular.tint(.white.opacity(0.05)), in: shape)
        }
    }
}

private struct AttachmentThumbnailView: View {
    let attachment: StagedImageAttachment

    var body: some View {
        let url = self.attachment.thumbnailFileURL ?? self.attachment.stagedFileURL
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.15))
            }
        }
    }
}
