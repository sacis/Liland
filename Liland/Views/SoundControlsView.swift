import SwiftUI

struct SoundControlsView: View {
    let viewModel: NotchViewModel

    @AppStorage(Preferences.showsPartVolumes) private var showsPartVolumes = false

    private var nowPlaying: NowPlayingController { viewModel.nowPlaying }
    private var audio: AudioLevelMonitor { nowPlaying.audioLevels }

    var body: some View {
        Group {
            if audio.permission == .denied {
                permissionRow
            } else {
                VStack(spacing: 12) {
                    isolationRow
                    if showsPartVolumes {
                        volumesRow
                    } else {
                        equalizerRow
                    }
                }
            }
        }
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Isolation

    private var isolationRow: some View {
        let isolated = audio.adjustments.isolated
        return HStack(spacing: 6) {
            pill("Full Mix", isSelected: isolated.isEmpty) {
                audio.adjustments.isolated = []
            }
            ForEach(audio.isolatableParts, id: \.self) { part in
                pill(Self.title(of: part), isSelected: isolated.contains(part)) {
                    audio.adjustments.toggle(part)
                }
            }
            Spacer(minLength: 8)
            Button {
                showsPartVolumes.toggle()
            } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(showsPartVolumes ? 0.95 : 0.6))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(showsPartVolumes ? 0.16 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Part Volumes")
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
        .animation(.easeOut(duration: 0.15), value: isolated)
    }

    private func pill(_ title: LocalizedStringKey, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
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

    private static func title(of part: AudioAdjustments.Part) -> LocalizedStringKey {
        switch part {
        case .vocals: "Vocals"
        case .guitar: "Guitar"
        case .bass: "Bass"
        case .drums: "Drums"
        }
    }

    // MARK: - Part Volumes

    private var volumesRow: some View {
        let isolated = audio.adjustments.isolated
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(audio.isolatableParts, id: \.self) { part in
                volumeColumn(
                    Self.title(of: part),
                    volume: audio.adjustments.volume(part),
                    isAudible: isolated.isEmpty || isolated.contains(part)
                ) { audio.adjustments.setVolume($0, for: part) }
            }
            volumeColumn("Others", volume: audio.adjustments.othersVolume, isAudible: isolated.isEmpty) {
                audio.adjustments.setOthersVolume($0)
            }
        }
    }

    private func volumeColumn(
        _ title: LocalizedStringKey,
        volume: Float,
        isAudible: Bool,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        let percent = (volume * 100).rounded()
        return VStack(spacing: 3) {
            BandSlider(
                value: percent,
                range: AudioAdjustments.volumeRange.lowerBound * 100...AudioAdjustments.volumeRange.upperBound * 100,
                step: 5,
                color: nowPlaying.accentColor,
                help: "\(Int(percent))%",
                onChange: { onChange($0 / 100) },
                onEditing: editing
            )
            .frame(height: 64)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.45))
                .frame(height: 11)
        }
        .opacity(isAudible ? 1 : 0.35)
        .frame(maxWidth: .infinity)
    }

    private func editing(_ isEditing: Bool) {
        if isEditing { viewModel.beginInteraction() } else { viewModel.endInteraction() }
    }

    // MARK: - Equalizer

    private var equalizerRow: some View {
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

    private func bandColumn(_ band: Int) -> some View {
        let gain = audio.adjustments.gain(band)
        return VStack(spacing: 3) {
            BandSlider(
                value: gain,
                range: AudioAdjustments.gainRange,
                step: 1,
                color: nowPlaying.accentColor,
                help: gain > 0 ? "+\(Int(gain)) dB" : "\(Int(gain)) dB",
                onChange: { audio.adjustments.setGain($0, for: band) },
                onEditing: editing
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

private struct BandSlider: View {
    let value: Float
    let range: ClosedRange<Float>
    let step: Float
    let color: Color
    let help: String
    let onChange: (Float) -> Void
    let onEditing: (Bool) -> Void

    @State private var isDragging = false

    private static let knobSize: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let usable = height - Self.knobSize
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
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
                        var next = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                        next = min(max((next / step).rounded() * step, range.lowerBound), range.upperBound)
                        if next != value { onChange(next) }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditing(false)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .help(Text(verbatim: help))
    }
}
