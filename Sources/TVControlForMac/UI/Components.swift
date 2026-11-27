// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

// The pages' building blocks. Every page is a grouped form, like a pane in System
// Settings: short rows with the control on the trailing edge. Anything that needs more
// than a few words of explanation goes behind an InfoTip instead of onto the page.

/// A page of the main window: a grouped form with the page's name in the title bar.
struct SettingsPage<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .navigationTitle(title)
    }
}

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

/// A group of rows in a page, with an optional heading and InfoTip.
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
        Section {
            content
        } header: {
            if let title {
                HStack(spacing: 5) {
                    Text(title)
                    if let info { InfoTip(info) }
                }
            }
        }
    }
}

/// A row's label: a short title, with an optional second line and InfoTip.
struct RowLabel: View {
    let title: String
    var subtitle: String?
    var info: String?

    init(_ title: String, subtitle: String? = nil, info: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.info = info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                if let info { InfoTip(info) }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One row in a `SettingsGroup`: a label and the control on the trailing edge.
struct SettingRow<Control: View>: View {
    private let label: RowLabel
    private let control: Control

    init(_ title: String, subtitle: String? = nil, info: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.label = RowLabel(title, subtitle: subtitle, info: info)
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control
        } label: {
            label
        }
    }
}

/// A row whose control is a switch.
struct ToggleRow: View {
    private let label: RowLabel
    @Binding private var isOn: Bool

    init(_ title: String, subtitle: String? = nil, info: String? = nil, isOn: Binding<Bool>) {
        self.label = RowLabel(title, subtitle: subtitle, info: info)
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            label
        }
    }
}

/// A row whose control is a pop-up menu of tagged choices.
struct PickerRow<Value: Hashable, Options: View>: View {
    private let label: RowLabel
    @Binding private var selection: Value
    private let options: Options

    init(_ title: String, subtitle: String? = nil, info: String? = nil,
         selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.label = RowLabel(title, subtitle: subtitle, info: info)
        self._selection = selection
        self.options = options()
    }

    var body: some View {
        Picker(selection: $selection) {
            options
        } label: {
            label
        }
    }
}
