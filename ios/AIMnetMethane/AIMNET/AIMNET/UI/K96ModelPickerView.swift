import SwiftUI

/// Choose which K96 methane model's reading the app shows and records. Every model of the bundled
/// `k96_config.json` is listed; picking one mid power-on rebuilds it from the frames of the power-on (same zero).
struct K96ModelPickerView: View {
    @ObservedObject var bleManager: BLEManager

    var body: some View {
        ZStack {
            FuturisticBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FuturisticPanel("Automatic", icon: "wand.and.stars") {
                        row(
                            key: BLEManager.automaticModelKey,
                            title: "Recommended for the tube position",
                            subtitle: "Tube at inlet: \(bleManager.recommendedModelKey(tubeAtInlet: true)) · old position: \(bleManager.recommendedModelKey(tubeAtInlet: false)). Follows the setting on the monitor screen.",
                            badge: nil
                        )
                    }
                    section("Tube at the device inlet", icon: "arrow.down.to.line", inlet: true)
                    section("Tube at the old position", icon: "arrow.left.and.right", inlet: false)
                    Text("Every model is a frozen file from the AIMNet_realtime package. Models are trained for one tube position: using one with the other position can be off by tens to hundreds of ppm. Model notes are from k96/config.json.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Methane Model")
    }

    private func section(_ title: String, icon: String, inlet: Bool) -> some View {
        let models = bleManager.availableModels.filter { $0.isInletModel == inlet }
        let recommended = bleManager.recommendedModelKey(tubeAtInlet: inlet)
        return FuturisticPanel(title, icon: icon) {
            ForEach(models) { spec in
                row(key: spec.key, title: spec.key, subtitle: spec.label, badge: spec.key == recommended ? "recommended" : nil)
                if spec.key != models.last?.key {
                    Divider().overlay(.white.opacity(0.12))
                }
            }
        }
    }

    private func row(key: String, title: String, subtitle: String, badge: String?) -> some View {
        Button {
            bleManager.selectedModelKey = key
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: bleManager.selectedModelKey == key ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(bleManager.selectedModelKey == key ? FuturisticPalette.success : .white.opacity(0.4))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if let badge {
                            Text(badge.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(FuturisticPalette.success)
                        }
                    }
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
