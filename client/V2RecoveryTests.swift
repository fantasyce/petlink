import AppKit
import Foundation

// Opt-in model/transport coverage. This does not put the computer to sleep;
// native UI reconnect is verified separately with real controls.
@main struct V2RecoveryTests {
 @MainActor static func main() {
  let app=NSApplication.shared;app.setActivationPolicy(.accessory)
  Task { @MainActor in
   do {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),profile=CommandLine.arguments[2]
    guard profile.hasPrefix("wake-"),!profile.contains("/"),profile != "default" else{throw CocoaError(.validationMissingMandatoryProperty)}
    let endpoint=try String(contentsOf:root.appendingPathComponent("endpoint"),encoding:.utf8)
    guard let url=URL(string:endpoint),url.scheme=="http",url.host=="127.0.0.1" else{throw URLError(.badURL)}
    for name in [profile,profile+"-peer"] {
     UserDefaults(suiteName:"com.fantasyce.petlink."+name)!.set(false,forKey:"codex-auto-active")
    }
    setenv("CODEX_HOME",root.path,1);setenv("CLAUDE_CONFIG_DIR",root.path,1);setenv("DSH_HOME",root.path,1)
    let a=V2ClientModel(profile:profile,endpointOverride:endpoint),b=V2ClientModel(profile:profile+"-peer",endpointOverride:endpoint)
    defer{a.disconnect();b.disconnect();a.pets.hideAll();b.pets.hideAll()}
    func until(_ label:String,_ condition:()->Bool)async throws {
     for _ in 0..<150 {if condition(){print("PASS "+label);return};try await Task.sleep(nanoseconds:100_000_000)}
     throw NSError(domain:"V2RecoveryTest",code:1,userInfo:[NSLocalizedDescriptionKey:label])
    }
    try await until("both isolated clients connected"){a.connected && b.connected && a.snapshot != nil && b.snapshot != nil}
    precondition(a.friendInteractionEnabled && b.friendInteractionEnabled,"new clients default to interaction enabled")
    a.setFriendInteractionEnabled(false)
    a.systemSuspend();b.systemSuspend()
    try await Task.sleep(nanoseconds:500_000_000)
    precondition(!a.connected && !b.connected && a.pets.visibleOwners.isEmpty && b.pets.visibleOwners.isEmpty,"sleep hides owned panels and stops transports")
    a.systemResume();b.systemResume()
    try await until("enabled client reconnects after model wake"){b.connected}
    try await Task.sleep(nanoseconds:3_500_000_000)
    precondition(!a.friendInteractionEnabled && !a.connected,"wake must not undo the user's off switch or trigger delayed reconnect")
    a.setFriendInteractionEnabled(true)
    try await until("explicit interaction on reconnects"){a.connected}
    let own=a.snapshot!.selfID
    guard let host=b.snapshot?.contacts.first(where:{$0.accountID==own}) else{throw CocoaError(.fileReadCorruptFile)}
    b.requestVisit(host)
    try await until("visit before model sleep"){b.snapshot?.own.phase=="visit" && a.pets.visibleOwners.count==2}
    a.systemSuspend()
    precondition(a.pets.visibleOwners.isEmpty)
    try await until("host sleep returns visitor home"){b.snapshot?.own.phase=="home" && b.pets.visibleOwners.count==1}
    a.systemResume()
    try await until("host wake restores one own pet"){a.connected && a.pets.visibleOwners==[own]}
    // Invoke the actual notification observers inside this isolated process.
    // These local posts do not suspend the OS or another running App.
    NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.willSleepNotification,object:nil)
    try await until("sleep observer stops both clients"){!a.connected && !b.connected && a.pets.visibleOwners.isEmpty && b.pets.visibleOwners.isEmpty}
    NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didWakeNotification,object:nil)
    try await until("wake observer reconnects both clients"){a.connected && b.connected}
    print("V2 model/real local transport: sleep/wake observers, hidden leases, visit recall, off-switch preservation and explicit reconnect PASS (not physical sleep acceptance)")
    exit(0)
   } catch {
    print("V2 model recovery FAIL: \(error)")
    exit(1)
   }
  }
  app.run()
 }
}
