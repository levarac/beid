import SwiftUI

@main
struct BeidLabApp: App {
  @StateObject private var coordinator: AppCoordinator
  @StateObject private var bootstrap: LabControlBootstrap

  init() {
    let coordinator = AppCoordinator()
    _coordinator = StateObject(wrappedValue: coordinator)
    let identity = try? LabControlIdentity(
      runId: ProcessInfo.processInfo.environment["BEID_LAB_RUN_ID"] ?? "",
      role: ProcessInfo.processInfo.environment["BEID_LAB_ROLE"] ?? "",
      deviceId: ProcessInfo.processInfo.environment["BEID_LAB_DEVICE_ID"] ?? "",
      generation: Int(ProcessInfo.processInfo.environment["BEID_LAB_GENERATION"] ?? "-1") ?? -1,
      token: ProcessInfo.processInfo.environment["BEID_LAB_TOKEN"] ?? "",
      protocolVersion: Int(ProcessInfo.processInfo.environment["BEID_LAB_PROTOCOL_VERSION"] ?? "-1") ?? -1
    )
    let brokerURL = URL(string: ProcessInfo.processInfo.environment["BEID_LAB_BROKER_URL"] ?? "")
    _bootstrap = StateObject(wrappedValue: LabControlBootstrap(
      identity: identity, sensing: coordinator.sensingCoordinator,
      brokerURL: brokerURL, broker: brokerURL.map { _ in URLSessionLabWebSocketClient() }
    ))
  }

  var body: some Scene {
    WindowGroup {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("beid Lab").font(.title2.weight(.semibold))
          LabeledContent("接続状態", value: bootstrap.status)
          LabeledContent("role", value: bootstrap.roleDescription)
          LabeledContent("device", value: bootstrap.deviceDescription)
          LabeledContent("最後の処理", value: bootstrap.lastCommand)
          LabeledContent("最後のsnapshot", value: bootstrap.lastSnapshotSummary)
          LabeledContent("submission", value: bootstrap.submissionDescription)
          Text("この画面は認証済み検証ホストとの読み取り専用接続を表示します。join、RF成功、署名record保存の証明ではありません。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding()
      }
        .task { bootstrap.start() }
        .onDisappear { bootstrap.stop() }
    }
  }
}
