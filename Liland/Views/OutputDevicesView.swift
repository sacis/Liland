import SwiftUI

struct OutputDevicesView: View {
    let viewModel: NotchViewModel

    private var outputs: OutputDevices { viewModel.outputs }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: viewModel.geometry.notchSize.height)

            content
                .frame(height: NotchGeometry.devicesListHeight(rows: outputs.rows), alignment: .top)
                .padding(.top, NotchGeometry.devicesTopPadding)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }

    private var header: some View {
        HStack {
            Button { viewModel.showsDevices = false } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Audio Output")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Back"))

            Spacer()

            if let icon = viewModel.nowPlaying.activePlayer?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch outputs.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: NotchGeometry.deviceRowHeight)
        case .ready where outputs.devices.isEmpty:
            MessageRow(
                icon: "speaker.slash",
                title: String(localized: "No devices found"),
                subtitle: outputs.source == .spotify ? String(localized: "Open Spotify on the device you want to use") : nil,
                actionTitle: String(localized: "Try Again"),
                action: outputs.reload
            )
        case .ready:
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: NotchGeometry.deviceRowSpacing) {
                    ForEach(outputs.devices) { device in
                        DeviceRow(
                            device: device,
                            isSwitching: outputs.switchingID == device.id,
                            accent: viewModel.nowPlaying.accentColor
                        ) {
                            outputs.select(device)
                        }
                    }
                }
            }
            .scrollDisabled(outputs.devices.count <= NotchGeometry.maxVisibleDeviceRows)
        case .signedOut:
            MessageRow(
                icon: "person.crop.circle",
                title: String(localized: "Sign in to Spotify"),
                subtitle: String(localized: "Choose where Spotify plays, right from here"),
                actionTitle: String(localized: "Sign In"),
                action: outputs.signIn
            )
        case .signingIn:
            MessageRow(
                icon: "safari",
                title: String(localized: "Finish signing in in your browser"),
                subtitle: nil,
                actionTitle: String(localized: "Try Again"),
                action: outputs.signIn
            )
        case .failed(let title, let subtitle):
            MessageRow(
                icon: "exclamationmark.triangle",
                title: title,
                subtitle: subtitle,
                actionTitle: String(localized: "Try Again"),
                action: outputs.reload
            )
        }
    }
}

private struct DeviceRow: View {
    let device: OutputDevice
    let isSwitching: Bool
    let accent: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: device.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(device.isActive ? accent : .white.opacity(0.75))
                    .frame(width: 22)

                Text(verbatim: device.name)
                    .font(.system(size: 13, weight: device.isActive ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isSwitching {
                    ProgressView().controlSize(.small)
                } else if device.isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: NotchGeometry.deviceRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(isHovering && !device.isActive ? 0.12 : device.isActive ? 0.09 : 0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!device.isEnabled)
        .opacity(device.isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

private struct MessageRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            Spacer(minLength: 8)

            Button(action: action) {
                Text(verbatim: actionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.16)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .frame(height: NotchGeometry.deviceRowHeight)
    }
}
