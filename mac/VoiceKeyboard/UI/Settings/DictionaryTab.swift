import SwiftUI
import VoiceKeyboardCore

struct DictionaryTab: View {
    @State var settings: UserSettings
    let onSave: (UserSettings) -> Void
    @State private var newTerm: String = ""

    var body: some View {
        VStack {
            HStack {
                TextField("Add term", text: $newTerm)
                Button("Add") {
                    let t = newTerm.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, !settings.customDict.contains(t) else { return }
                    settings.customDict.append(t)
                    newTerm = ""
                    onSave(settings)
                }
                .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(settings.customDict, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button("Remove") {
                            settings.customDict.removeAll { $0 == term }
                            onSave(settings)
                        }
                    }
                }
            }
        }
        .padding()
    }
}
