import SwiftUI

struct ExplorerNavigationBar: View {
    @EnvironmentObject var model: AppModel
    let location: URL
    var body: some View {
        HStack(spacing: 10) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }.help("Back").disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }.help("Forward").disabled(!model.canGoForward)
            Button {
                let parent = location.deletingLastPathComponent()
                if model.selection == .browser { model.browse(parent) } else { model.loadMap(parent) }
            } label: { Image(systemName: "arrow.up") }.help("Enclosing folder").disabled(location.path == "/")
            Text(location.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(location.path)
            Spacer(minLength: 8)
            Picker("View", selection: Binding(get: { model.selection }, set: { model.switchExplorer(to: $0) })) {
                Label("Map", systemImage: "rectangle.3.group").tag(SidebarTab.spaceMap)
                Label("List", systemImage: "list.bullet").tag(SidebarTab.browser)
            }.pickerStyle(.segmented).frame(width: 150)
            Button {
                if model.selection == .browser { model.browse(location, refresh: true) }
                else { model.loadMap(location, refresh: true) }
            } label: { Image(systemName: "arrow.clockwise") }.help("Measure this folder again").disabled(model.isCleaning || model.mapLoading || model.browserIsScanning)
            Button { model.chooseFolder() } label: { Label("Open folder…", systemImage: "folder.badge.plus") }.disabled(model.isCleaning)
        }.controlSize(.small).padding(.vertical, 8)
    }
}
