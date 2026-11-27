// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

// The pages' building blocks. Every page is a title and short rows; anything that needs
// more than a few words of explanation goes behind an InfoTip instead of onto the page.

/// A small "i" button that shows a longer explanation in a popover.
struct InfoTip: View {
    let text: String
    @State private var shown = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("More about this")
        .accessibilityLabel("More about this")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(14)
        }
    }
}

/// A titled group of rows drawn as one rounded card with hairlines between the rows,
/// like a section in System Settings. The title and its InfoTip are optional.
struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let info: String?
    private let content: Content

    init(_ title: String? = nil, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.info = info
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let info { InfoTip(info) }
                }
                .padding(.leading, 2)
            }
            _VariadicView.Tree(DividedRows()) { content }
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary.opacity(0.45))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
        }
    }
}

// Lays the group's rows out in a column with a hairline between each pair.
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Divider().padding(.leading, 14)
                }
            }
        }
    }
}

/// One row in a `SettingsGroup`: an optional icon, a short title (with an optional second
/// line and InfoTip), and the control on the trailing edge.
struct SettingRow<Control: View>: View {
    private let icon: String?
    private let title: String
    private let subtitle: String?
    private let info: String?
    private let control: Control

    init(_ title: String, icon: String? = nil, subtitle: String? = nil, info: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.info = info
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let info { InfoTip(info) }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// A `SettingRow` whose control is a switch.
struct ToggleRow: View {
    let title: String
    var icon: String?
    var subtitle: String?
    var info: String?
    @Binding var isOn: Bool

    init(_ title: String, icon: String? = nil, subtitle: String? = nil, info: String? = nil,
         isOn: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.info = info
        self._isOn = isOn
    }

    var body: some View {
        SettingRow(title, icon: icon, subtitle: subtitle, info: info) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
