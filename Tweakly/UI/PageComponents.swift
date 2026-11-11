import SwiftUI

/// What the pages of the window are built from, so that they read as parts of one app. They are taken from System
/// Settings itself.

/// A symbol, what a feature is and what it does, as at the top of an app's page in Notifications.
struct FeatureLabel: View {
    /// As wide as the icons at the top of the pages in System Settings.
    private static var symbolWidth: CGFloat { 28 }

    let symbol: String
    let title: Text
    let detail: Text

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: Self.symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The first row of a page whose feature can be turned on and off. Its switch is larger than the others, as in System
/// Settings, because everything below depends on it.
struct MainSwitch: View {
    let symbol: String
    let title: Text
    let detail: Text
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            FeatureLabel(symbol: symbol, title: title, detail: detail)
        }
        .controlSize(.small)
    }
}

/// A section's title with what the section is about under it, above the group, as for Notification Center in System
/// Settings.
struct SectionTitle: View {
    let title: Text
    let detail: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            detail
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
        }
    }
}

/// A setting on a scale that has no number worth reading, as Key Repeat Delay on the Keyboard page: named at its ends,
/// with a mark for each stop.
struct ScaleRow: View {
    let title: Text
    var detail: Text?
    let stops: Int
    @Binding var stop: Int
    let lowest: Text
    let highest: Text
    /// What VoiceOver says, as the stops have no names on screen.
    let spoken: String

    var body: some View {
        let last = Double(stops - 1)
        Slider(
            value: Binding(get: { Double(stop) }, set: { stop = Int($0.rounded()) }), in: 0...last, step: 1
        ) {
            title
            if let detail { detail }
        } tick: { value in
            switch value {
            case 0: SliderTick(value) { lowest }
            case last: SliderTick(value) { highest }
            default: SliderTick(value)
            }
        }
        .accessibilityValue(spoken)
    }
}

/// One choice between looks: a real rendering with a caption under it, as in Appearance in System Settings.
struct LookChoice<Preview: View>: View {
    private static var cornerRadius: CGFloat { 8 }

    let title: String
    let isSelected: Bool
    /// A name someone typed can be long and has to stay in one line; the app's own captions may wrap.
    var keepsToOneLine = false
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview()
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(.quaternary, in: .rect(cornerRadius: Self.cornerRadius))
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Self.cornerRadius)
                                .strokeBorder(.tint, lineWidth: 2)
                        } else if contrast == .increased {
                            RoundedRectangle(cornerRadius: Self.cornerRadius)
                                .strokeBorder(.separator, lineWidth: 1)
                        }
                    }
                caption
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var caption: some View {
        let text = Text(title)
            .font(.caption)
            .fontWeight(isSelected ? .semibold : .regular)
        if keepsToOneLine {
            text.lineLimit(1).truncationMode(.middle)
        } else {
            text.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A rarer part of a page, opened from a button below its last group, as Options on the Battery page: the same kind of
/// form with one button to close it, because what changes here applies at once.
struct DetailsSheet<Content: View>: View {
    private static var width: CGFloat { 550 }

    var height: CGFloat = 520
    /// The one action that is not about closing, such as restoring defaults, at the other end of the bottom bar.
    var resetTitle: LocalizedStringKey?
    var canReset = false
    var reset: () -> Void = {}
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .frame(width: Self.width, height: height)
        .toolbar {
            if let resetTitle {
                ToolbarItem(placement: .automatic) {
                    Button(resetTitle, action: reset)
                        .disabled(!canReset)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// A row that opens another page, as the rows of Screen Time and Privacy & Security in System Settings: a symbol, a
/// name with an optional line under it, where it is at now, and a chevron.
struct LinkRow<Value: View>: View {
    /// Wide enough for the symbols of the sidebar, so that the names line up.
    static var symbolWidth: CGFloat { 22 }

    let symbol: String
    var symbolScale: Image.Scale = .medium
    let title: Text
    var detail: Text?
    let action: () -> Void
    @ViewBuilder let value: () -> Value

    var body: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    value()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            } label: {
                Label {
                    title
                    if let detail { detail }
                } icon: {
                    Image(systemName: symbol)
                        .imageScale(symbolScale)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.symbolWidth)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
