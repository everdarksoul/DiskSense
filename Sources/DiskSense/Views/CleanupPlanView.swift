import SwiftUI

final class CleanupPlanState: ObservableObject {
    @Published var goalBytes: Int64 = 5_000_000_000
    @Published var plan: CleanupPlan?
    @Published var selected: Set<String> = []
    @Published var invalidationMessage: String?

    func reset(_ message: String? = nil) {
        plan = nil
        selected = []
        invalidationMessage = message
    }
}

struct CleanupPlanView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var state = CleanupPlanState()
    private var eligible: [JunkItem] { CleanupPlanner.eligibleCandidates(from: model.junk) }
    private var selected: [JunkItem] { state.plan?.candidates.filter { state.selected.contains($0.path) } ?? [] }
    private var selectedBytes: Int64 { CleanupPlanner.totalBytes(selected) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading
                goalCard
                if let message = state.invalidationMessage {
                    Label(message, systemImage: "arrow.clockwise.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let plan = state.plan { proposal(plan) }
                else { startingPoint }
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle")
                    Text("A plan uses the latest measured sizes. Apps may rebuild caches or download data again; close the related apps first. Moving files to Trash does not free volume space until Trash is emptied, and snapshots or shared blocks can affect the space reclaimed.")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onReceive(model.$junk) { items in
            guard let plan = state.plan else { return }
            if plan.sourceSignature != CleanupPlanner.signature(of: items) {
                state.reset("The cache inventory changed. Build a fresh plan using the latest measurements.")
            }
        }
        .onChange(of: state.goalBytes) { _ in state.reset() }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [.teal.opacity(0.18), .indigo.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 28)).foregroundStyle(.teal)
            }.frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("Make room for something good.").font(.system(size: 29, weight: .bold, design: .rounded))
                Text("Choose a target. Get a clear, editable plan from cache and build data.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your space target").font(.title3.bold())
                    Text("\(ByteFormat.string(CleanupPlanner.totalBytes(eligible))) measured across \(eligible.count) eligible candidates")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "target").font(.title2).foregroundStyle(.teal)
            }
            HStack(spacing: 14) {
                Picker("Target", selection: $state.goalBytes) {
                    Text("1 GB").tag(Int64(1_000_000_000))
                    Text("5 GB").tag(Int64(5_000_000_000))
                    Text("10 GB").tag(Int64(10_000_000_000))
                }.pickerStyle(.segmented).frame(maxWidth: 370)
                Spacer(minLength: 0)
                Button { buildPlan() } label: { Label("Build my plan", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(model.isScanning || model.isCleaning || eligible.isEmpty)
            }
            Text(model.isScanning ? "Your scan is updating the inventory. Build a plan when it finishes." : "Largest candidates come first. Enclosing folders are counted once. You decide what goes into the final review.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.teal.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.teal.opacity(0.18)))
    }

    private var startingPoint: some View {
        HStack(alignment: .top, spacing: 24) {
            principle("Cache & build data", detail: "User caches, developer caches and generated build artifacts from the cleanup inventory.", symbol: "hammer")
            principle("Personal files stay yours", detail: "Documents, downloads, photos, app bundles and app support data are excluded from this planner.", symbol: "hand.raised")
            principle("You stay in control", detail: "Building a plan only proposes candidates. A separate review is required to move anything to Trash.", symbol: "checklist")
        }.padding(.vertical, 12)
    }

    private func principle(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.teal)
            Text(title).font(.callout.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func proposal(_ plan: CleanupPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ByteFormat.string(selectedBytes)) selected").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("of your \(ByteFormat.string(plan.goalBytes)) target · \(selected.count) candidates")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review \(selected.count) selected…") {
                    guard plan.sourceSignature == CleanupPlanner.signature(of: model.junk) else {
                        state.reset("The cache inventory changed. Build a fresh plan using the latest measurements.")
                        return
                    }
                    model.reviewCleanup(selected.map { CleanupCandidate(url: URL(fileURLWithPath: $0.path), bytes: $0.bytes, reason: "Cleanup plan · \($0.note)") })
                }.buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(selected.isEmpty || model.isScanning || model.isCleaning)
            }
            ProgressView(value: min(Double(selectedBytes) / Double(max(1, plan.goalBytes)), 1))
                .tint(selectedBytes >= plan.goalBytes ? .teal : .orange)
                .accessibilityLabel("Selected size toward target")
            if !plan.reachesGoal {
                Label("The eligible candidates fall \(ByteFormat.string(plan.shortfallBytes)) short of this target. This plan contains everything available in these categories.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if selectedBytes < plan.goalBytes {
                Text("Your edited selection is \(ByteFormat.string(plan.goalBytes - selectedBytes)) below the target.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Selected measured size meets the target. Actual space reclaimed can differ.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.teal)
            }
            HStack {
                Text("PROPOSED CANDIDATES").font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Button("Select proposal") { state.selected = Set(plan.candidates.map(\.path)) }
                Button("Clear selection") { state.selected = [] }
            }.controlSize(.small)
            LazyVStack(spacing: 0) {
                ForEach(plan.candidates) { item in
                    Toggle(isOn: Binding(get: { state.selected.contains(item.path) }, set: { value in
                        if value { state.selected.insert(item.path) } else { state.selected.remove(item.path) }
                    })) {
                        HStack(spacing: 13) {
                            Image(systemName: item.kind.symbol).font(.title3).foregroundStyle(.teal).frame(width: 25)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.callout.bold())
                                Text("\(item.kind.rawValue) · \(item.note)").font(.caption).foregroundStyle(.secondary)
                                Text(item.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(ByteFormat.string(item.bytes)).font(.body.monospacedDigit())
                            Button { model.reveal(URL(fileURLWithPath: item.path)) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless).help("Reveal in Finder")
                        }.padding(.vertical, 14)
                    }.toggleStyle(.checkbox)
                    Divider()
                }
            }
        }
    }

    private func buildPlan() {
        let plan = CleanupPlanner.makePlan(from: model.junk, goalBytes: state.goalBytes)
        state.plan = plan
        state.selected = Set(plan.candidates.map(\.path))
        state.invalidationMessage = nil
    }
}
