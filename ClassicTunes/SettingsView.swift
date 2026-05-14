import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appearanceManager: AppearanceManager
    @AppStorage("albumGridBackgroundStyle") private var albumGridBackgroundStyle: String = "dark" // there are better ways but nah

    var body: some View {
        Form {
            Section(header: Text("settings.appearance")) {
                Picker("settings.appAppearance", selection: $appearanceManager.appAppearance) {
                    Text("settings.system").tag("system")
                    Text("settings.light").tag("light")
                    Text("settings.dark").tag("dark")
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
            
            Section(header: Text("settings.albumGrid")) {
                Picker("settings.albumGrid.background", selection: $albumGridBackgroundStyle) {
                    Text("settings.light").tag("light")
                    Text("settings.dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Text("settings.albumGrid.note")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 360)
        .preferredColorScheme(appearanceManager.currentColorScheme())
    }

    private var helpText: String {
        switch appearanceManager.appAppearance {
        case "light": return NSLocalizedString("settings.appearanceHelp.light", comment: "light")
        case "dark": return NSLocalizedString("settings.appearanceHelp.dark", comment: "dark")
        default: return NSLocalizedString("settings.appearanceHelp.system", comment: "system")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppearanceManager())
}
