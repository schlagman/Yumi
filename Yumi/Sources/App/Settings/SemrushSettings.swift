import SwiftUI

/// Settings, Modules, Semrush: the API key, a test, and the month's units, the tile's gauge total.
struct SemrushSettingsSection: View {
    /// The Keychain key of the Semrush API key. Read off the main actor, by the API's key closure.
    nonisolated static let keyName = "semrush-api-key"

    @State private var key = ""
    @State private var connected = KeychainStore.shared.get(Self.keyName) != nil
    @State private var status: String?
    @State private var failed = false
    @State private var loading = false
    @AppStorage(SemrushModule.monthlyKey) private var monthly = SemrushModule.defaultMonthly

    private var api: SemrushAPI { SemrushAPI(key: { KeychainStore.shared.get(Self.keyName) }) }

    var body: some View {
        Section {
            if connected {
                LabeledContent(loc("État")) { SettingsStatus(text: status ?? loc("Clé enregistrée"), tone: failed ? .warning : .ok) }
                HStack {
                    Button(loc("Tester")) { Task { await test() } }.disabled(loading)
                    Button(loc("Retirer la clé")) {
                        KeychainStore.shared.remove(Self.keyName)
                        connected = false
                        status = nil
                        failed = false
                        keyChanged()
                    }
                }
            } else {
                LabeledContent(loc("Clé d'API")) {
                    HStack {
                        SecureField("", text: $key).labelsHidden()
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        Button(loc("Brancher")) {
                            KeychainStore.shared.set(Self.keyName, value: key.trimmingCharacters(in: .whitespacesAndNewlines))
                            key = ""
                            connected = true
                            keyChanged()
                            Task { await test() }
                        }
                        .disabled(key.nonEmptyTrimmed == nil)
                    }
                }
            }
            LabeledContent(loc("Unités par mois")) {
                TextField("", value: $monthly, format: .number).labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                    .onChange(of: monthly) { changed() }
            }
        } header: {
            Text("Semrush")
        } footer: {
            SettingsHelp(loc("Ta clé d'API est dans Semrush, Subscription info › API units. Je ne fais qu'une requête, celle du solde, que Semrush ne facture pas. Le solde est celui du compte : toute l'équipe compte dans la consommation du jour."))
        }
    }

    /// The balance, read once: the same free request as the tile.
    private func test() async {
        loading = true
        defer { loading = false }
        do {
            let balance = try await api.balance()
            status = balance == 0 ? SemrushModule.emptyBalance : loc("\(SemrushModule.units(balance)) unités restantes")
            failed = balance == 0
        } catch {
            status = FrenchText.sentenceStart(error.reason)
            failed = true
        }
    }

    /// Another key, or none: the count of the day starts over.
    private func keyChanged() {
        UserDefaults.standard.removeObject(forKey: SemrushDay.key)
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: SemrushModule.settingsChanged, object: nil)
    }
}
