import AppKit
import Foundation

@main struct V2InvalidSessionTests {
 @MainActor static func main() {
  let app=NSApplication.shared;app.setActivationPolicy(.accessory)
  Task { @MainActor in
   do {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),profile=CommandLine.arguments[2]
    guard profile.hasPrefix("wake-invalid-"),!profile.contains("/") else{throw CocoaError(.validationMissingMandatoryProperty)}
    let endpoint=try String(contentsOf:root.appendingPathComponent("endpoint"),encoding:.utf8)
    guard URL(string:endpoint)?.host=="127.0.0.1" else{throw URLError(.badURL)}
    let defaults=UserDefaults(suiteName:"com.fantasyce.petlink."+profile)!
    defaults.set(false,forKey:"codex-auto-active")
    setenv("CODEX_HOME",root.path,1);setenv("CLAUDE_CONFIG_DIR",root.path,1);setenv("DSH_HOME",root.path,1)
    let model=V2ClientModel(profile:profile,endpointOverride:endpoint)
    defer{model.disconnect();model.pets.hideAll()}
    var recovered=false
    for _ in 0..<120 {
     if !model.busy && !model.authenticated && Vault.read(profile)==nil {recovered=true;break}
     try await Task.sleep(nanoseconds:50_000_000)
    }
    guard recovered else{throw NSError(domain:"InvalidSession",code:1,userInfo:[NSLocalizedDescriptionKey:"confirmed invalid refresh must clear the old session and restore Google login"])}
    precondition(model.message=="登录已失效，请重新登录","a canceled old request must not overwrite the recovery explanation")
    precondition(model.endpoint==endpoint && !model.migrationRequired,"custom endpoint and Google login remain available")
    try await Task.sleep(nanoseconds:3_500_000_000)
    precondition(!model.authenticated && !model.connected && !model.connecting && Vault.read(profile)==nil,"invalid credentials must not enter another reconnect cycle")
    print("PASS invalid saved session: rejected refresh restores login, deletes stale session, preserves endpoint and stops reconnect")
    exit(0)
   }catch{print("Invalid-session recovery FAIL: \(error)");exit(1)}
  }
  app.run()
 }
}
