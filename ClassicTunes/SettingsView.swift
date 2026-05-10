import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appearanceManager: AppearanceManager
    @AppStorage("albumGridBackgroundStyle") private var albumGridBackgroundStyle: String = "dark" // there are better ways but nah

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
            
            Section(header: Text("Album Grid")) {
                Picker("Background", selection: $albumGridBackgroundStyle) {
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Text("When the app is in Dark appearance, the album grid will use Dark regardless of this setting.")
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
