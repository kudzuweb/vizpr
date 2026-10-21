import SwiftUI

/// Font families, each name set in its own font, with "System" first. A menu
/// picker would draw every name in the menu font, so this is a list.
struct FontFamilyList: View {
    /// nil = the system font.
    @Binding var family: String?
    let families: [String]

    private static let systemTag = ""

    var body: some View {
        List(selection: Binding(
            get: { family ?? Self.systemTag },
            set: { family = $0 == Self.systemTag ? nil : $0 }
        )) {
            Text("System").tag(Self.systemTag)
            ForEach(families, id: \.self) { name in
                Text(name).font(.custom(name, size: 14)).tag(name)
            }
        }
        .listStyle(.bordered)
        .frame(height: 150)
    }
}
