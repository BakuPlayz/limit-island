import SwiftUI

private struct JumpSheetContainer: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.12, green: 0.13, blue: 0.15))
    }
}

extension View {
    func sheetContainer() -> some View { modifier(JumpSheetContainer()) }
}
