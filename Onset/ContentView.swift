import SwiftData
import SwiftUI

/// Sidebar column width constants — template placeholder, will be replaced by feature implementation.
private enum SidebarLayout {
    static let minWidth: CGFloat = 180
    static let idealWidth: CGFloat = 200
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(self.items) { item in
                    NavigationLink {
                        Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                    } label: {
                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                    }
                }
                .onDelete(perform: self.deleteItems)
            }
            .navigationSplitViewColumnWidth(min: SidebarLayout.minWidth, ideal: SidebarLayout.idealWidth)
            .toolbar {
                ToolbarItem {
                    Button(action: self.addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select an item")
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            self.modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                self.modelContext.delete(self.items[index])
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
