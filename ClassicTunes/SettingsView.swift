import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appearanceManager: AppearanceManager

    var body: some View {
        Form {
            Section(header: Text("Appearance")) {
                Picker("App Appearance", selection: $appearanceManager.appAppearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceManager.appAppearance) { _ in
                    appearanceManager.applyAppearance()
                }

                Text(helpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(height: 40, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(minWidth: 360)
        .preferredColorScheme(appearanceManager.currentColorScheme())
    }

    private var helpText: String {
        switch appearanceManager.appAppearance {
        case "light": return "Forces the app to always use Light appearance."
        case "dark": return "Forces the app to always use Dark appearance."
        default: return "Follows the system appearance."
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppearanceManager())
}
