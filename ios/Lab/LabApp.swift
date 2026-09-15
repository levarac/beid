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
      VStack(spacing: 12) { Text("beid Lab"); Text(bootstrap.status).font(.caption) }
        .task { bootstrap.start() }
        .onDisappear { bootstrap.stop() }
    }
  }
}
