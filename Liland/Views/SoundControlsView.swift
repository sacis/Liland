import SwiftUI

/// Advanced mode, below the player: the part of the music to isolate, the equalizer bands and the pitch.
struct SoundControlsView: View {
    let viewModel: NotchViewModel

    private var nowPlaying: NowPlayingController { viewModel.nowPlaying }
    private var audio: AudioLevelMonitor { nowPlaying.audioLevels }

    var body: some View {
        Group {
            if audio.permission == .denied {
                permissionRow
            } else {
                VStack(spacing: 12) {
                    isolationRow
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(AudioAdjustments.bands.indices, id: \.self) { band in
                            bandColumn(band)
                        }
                        Rectangle()
                            .fill(.white.opacity(0.1))
                            .frame(width: 1, height: 56)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 12)
                        pitchColumn
                    }
                }
            }
        }
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Isolation

    private var isolationRow: some View {
        HStack(spacing: 6) {
            ForEach(AudioAdjustments.Isolation.allCases, id: \.self) { isolation in
                let isSelected = audio.adjustments.isolation == isolation
                Button {
                    audio.adjustments.isolation = isolation
                } label: {
                    Text(Self.title(of: isolation))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(isSelected ? .white.opacity(0.9) : .white.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            Spacer(minLength: 8)
            Button {
                audio.adjustments = .neutral
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(audio.adjustments == .neutral ? 0.25 : 0.75))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(audio.adjustments == .neutral)
            .help("Reset")
        }
        .animation(.easeOut(duration: 0.15), value: audio.adjustments.isolation)
    }

    private static func title(of isolation: AudioAdjustments.Isolation) -> LocalizedStringKey {
        switch isolation {
        case .none: "Full Mix"
        case .vocals: "Vocals"
        case .bass: "Bass"
        case .drums: "Drums"
        }
    }

    // MARK: - Equalizer

    private func bandColumn(_ band: Int) -> some View {
        VStack(spacing: 3) {
            BandSlider(
                value: audio.adjustments.gain(band),
                color: nowPlaying.accentColor,
                onChange: { audio.adjustments.setGain($0, for: band) },
                onEditing: { isEditing in
                    if isEditing { viewModel.beginInteraction() } else { viewModel.endInteraction() }
                }
            )
            .frame(height: 64)
            Text(verbatim: AudioAdjustments.bands[band].label)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .frame(height: 11)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pitch

    private var pitchColumn: some View {
        let pitch = audio.adjustments.pitch
        return VStack(spacing: 8) {
            HStack(spacing: 4) {
                stepButton("minus", help: "Lower Pitch", enabled: pitch > AudioAdjustments.pitchRange.lowerBound) {
                    audio.adjustments.pitch -= 1
                }
                Text(verbatim: pitch > 0 ? "+\(pitch)" : pitch < 0 ? "−\(-pitch)" : "0")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pitch == 0 ? .white.opacity(0.75) : nowPlaying.accentColor)
                    .frame(width: 28)
                stepButton("plus", help: "Raise Pitch", enabled: pitch < AudioAdjustments.pitchRange.upperBound) {
                    audio.adjustments.pitch += 1
                }
            }
            Text("Pitch")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(height: 11)
        }
        .frame(width: 104)
    }

    private func stepButton(_ systemName: String, help: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Permission

    private var permissionRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(0.1)))
            Text("Allow audio access to adjust the sound")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: AudioCapturePermission.openSettings) {
                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.16)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.top, 16)
    }
}

/// A vertical equalizer band: 0 dB in the middle, filled toward the value in the album color.
private struct BandSlider: View {
    let value: Float
    let color: Color
    let onChange: (Float) -> Void
    let onEditing: (Bool) -> Void

    @State private var isDragging = false

    private static let range = AudioAdjustments.gainRange
    private static let knobSize: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let usable = height - Self.knobSize
            let fraction = CGFloat((value - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound))
            let knobY = Self.knobSize / 2 + usable * (1 - fraction)
            let middle = height / 2

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(width: 4)
                Rectangle()
                    .fill(.white.opacity(0.3))
                    .frame(width: 10, height: 1)
                    .offset(y: middle)
                Capsule()
                    .fill(color)
                    .frame(width: 4, height: abs(knobY - middle))
                    .offset(y: min(knobY, middle))
                Circle()
                    .fill(.white)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .scaleEffect(isDragging ? 1.2 : 1)
                    .offset(y: knobY - Self.knobSize / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditing(true)
                        }
                        let fraction = 1 - Float((drag.location.y - Self.knobSize / 2) / usable)
                        var gain = Self.range.lowerBound + fraction * (Self.range.upperBound - Self.range.lowerBound)
                        gain = min(max(gain.rounded(), Self.range.lowerBound), Self.range.upperBound)
                        if gain != value { onChange(gain) }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditing(false)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .help(Text(verbatim: value > 0 ? "+\(Int(value)) dB" : "\(Int(value)) dB"))
    }
}
