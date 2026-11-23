import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        if model.state.pairing == nil {
            NavigationStack {
                PairingView(model: model)
            }
        } else {
            DashboardView(model: model)
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}
