import SwiftUI

/// The pieces every settings pane is built from: a card of rows, each row a
/// label on the left and its control on the right — the shape macOS System
/// Settings uses, so a pane needs no explaining.

/// A card of related rows, optionally under a title. Most cards go untitled;
/// the grouping itself says enough, and a title every few rows turns a pane
/// into a list of headings.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            SettingsCard { content }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
    }
}

/// Label on the left, control on the right, on one line — with a second line
/// of explanation for the few controls that genuinely need one.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var help: String?
    @ViewBuilder var trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        help: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.help = help
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .help(help ?? "")
    }
}

/// Secondary copy belonging to the row above it, kept inside the card rather
/// than floating between groups.
struct RowNote: View {
    let text: String
    var symbol: String?
    var tint: Color?
    var help: String?

    init(_ text: String, symbol: String? = nil, tint: Color? = nil, help: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.help = help
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(tint ?? .secondary)
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(symbol == nil ? (tint ?? Color.secondary) : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
        .padding(.top, -2)
        .help(help ?? "")
    }
}

/// Inset on the leading edge, the way a grouped list separates its rows.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 12)
    }
}

struct RowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

struct RowField: View {
    @Binding var text: String
    let prompt: String
    var width: CGFloat = 200

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .frame(width: width)
    }
}

/// A shortcut's keys, set in the small raised box macOS uses for them
/// everywhere else. Read-only — the one shortcut you can change is the
/// global hotkey, which has `HotkeyField` instead.
struct KeyCaps: View {
    let keys: String

    init(_ keys: String) {
        self.keys = keys
    }

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.07))
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
    }
}

extension View {
    /// A popup sized to its selection, as the right-hand control of a row.
    func rowPicker() -> some View {
        self.pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .font(.system(size: 12))
            .fixedSize()
    }
}
