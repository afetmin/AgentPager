import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            if model.state.pairing == nil {
                PairingView(model: model)
            } else {
                StatusView(model: model)
            }
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}
