import AppKit
import Foundation

@main struct V2AppearanceRecoveryTests {
 @MainActor static func main() {
  let app=NSApplication.shared;app.setActivationPolicy(.accessory)
  Task { @MainActor in
   do {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),profile=CommandLine.arguments[2]
    guard profile.hasPrefix("wake-appearance-"),!profile.contains("/"),profile != "default" else{throw CocoaError(.validationMissingMandatoryProperty)}
    let endpoint=try String(contentsOf:root.appendingPathComponent("endpoint"),encoding:.utf8)
    guard let url=URL(string:endpoint),url.scheme=="http",url.host=="127.0.0.1" else{throw URLError(.badURL)}
    let defaults=UserDefaults(suiteName:"com.fantasyce.petlink."+profile)!
    defaults.set(false,forKey:"codex-auto-active");defaults.set(8,forKey:"local-companion-style")
    setenv("CODEX_HOME",root.path,1);setenv("CLAUDE_CONFIG_DIR",root.path,1);setenv("DSH_HOME",root.path,1)
    let model=V2ClientModel(profile:profile,endpointOverride:endpoint)
    defer{model.systemSuspend()}
    guard !model.initialAppearanceReady,model.pets.visibleOwners.isEmpty else{throw NSError(domain:"V2AppearanceRecovery",code:3,userInfo:[NSLocalizedDescriptionKey:"pet appeared before restoring account appearance"])}
    func until(_ label:String,_ condition:()->Bool)async throws {
     for _ in 0..<200 {if condition(){print("PASS "+label);return};try await Task.sleep(nanoseconds:50_000_000)}
     throw NSError(domain:"V2AppearanceRecovery",code:1,userInfo:[NSLocalizedDescriptionKey:label])
    }
    try await until("server bear appearance connected"){model.connected && model.snapshot?.own.style==6}
    guard LocalCompanion(defaults:defaults).style==6 else{throw NSError(domain:"V2AppearanceRecovery",code:2,userInfo:[NSLocalizedDescriptionKey:"confirmed server appearance was not saved for the next launch"])}
    guard model.snapshot?.contacts.first(where:{$0.nickname=="阿青"})?.style==9 else{throw NSError(domain:"V2AppearanceRecovery",code:4,userInfo:[NSLocalizedDescriptionKey:"friend appearance did not follow scarf toast"])}
    let account=model.snapshot!.selfID
    guard LocalCompanion(defaults:defaults).savedStyle(accountID:account)==6 else{throw CocoaError(.validationMissingMandatoryProperty)}
    // A previous online drag is stored by account. A cold launch must use
    // that position for its first offline companion, before any socket reply.
    let screen=PetScreen.connected.first!
    let savedOrigin=NSPoint(x:screen.bounds.minX+50,y:screen.bounds.minY+60)
    PetPositionStore(defaults:defaults,profile:profile).save(owner:account,origin:savedOrigin,screen:screen)
    // Receive a change from the server, bypassing the local outfit action.
    model.send("style",fields:["style":7])
    try await until("server outfit change persisted"){model.snapshot?.own.style==7 && LocalCompanion(defaults:defaults).savedStyle(accountID:account)==7}
    model.systemSuspend()
    let restored=V2ClientModel(profile:profile,endpointOverride:"http://127.0.0.1:1")
    defer{restored.systemSuspend()}
    try await until("offline restart displays saved bear and outfit"){restored.initialAppearanceReady && restored.displayedStyle==7 && !restored.pets.visibleOwners.isEmpty}
    guard restored.pets.frame(restored.localOwnerID)?.origin==savedOrigin else{throw NSError(domain:"V2AppearanceRecovery",code:8,userInfo:[NSLocalizedDescriptionKey:"first offline companion used the default position instead of the account's saved position; frame=\(String(describing:restored.pets.frame(restored.localOwnerID))) expected=\(savedOrigin) authenticated=\(restored.authenticated)"])}
    print("PASS first offline companion starts at the saved account position")
    guard !restored.connected else{throw CocoaError(.validationMissingMandatoryProperty)}
    // A failed social transport must not blink the independent local pet on
    // every retry. Check the synchronous reconnect boundary as well as the
    // subsequent real connection-refused callbacks and scheduled retries.
    restored.connect()
    guard restored.pets.visibleOwners==[restored.localOwnerID] else{throw NSError(domain:"V2AppearanceRecovery",code:5,userInfo:[NSLocalizedDescriptionKey:"reconnect hid the local companion"])}
    for _ in 0..<160 {
     guard restored.pets.visibleOwners==[restored.localOwnerID] else{throw NSError(domain:"V2AppearanceRecovery",code:6,userInfo:[NSLocalizedDescriptionKey:"failed transport retry blinked the local companion"])}
     guard restored.pets.frame(restored.localOwnerID)?.origin==savedOrigin else{throw NSError(domain:"V2AppearanceRecovery",code:9,userInfo:[NSLocalizedDescriptionKey:"layout or reconnect moved the restored companion"])}
     try await Task.sleep(nanoseconds:50_000_000)
    }
    restored.pets.setHidden(true)
    restored.connect()
    try await Task.sleep(nanoseconds:500_000_000)
    guard restored.pets.visibleOwners.isEmpty else{throw NSError(domain:"V2AppearanceRecovery",code:7,userInfo:[NSLocalizedDescriptionKey:"reconnect undid manual hide"])}
    restored.pets.setHidden(false)
    guard restored.pets.visibleOwners==[restored.localOwnerID] else{throw CocoaError(.validationMissingMandatoryProperty)}
    print("PASS local companion stays visible across offline reconnects; manual hide preserved")
    restored.dressCompanion(6)
    restored.systemSuspend()
    let offlineEdited=V2ClientModel(profile:profile,endpointOverride:"http://127.0.0.1:1")
    defer{offlineEdited.systemSuspend()}
    try await until("offline saved pet survives another restart"){offlineEdited.initialAppearanceReady && offlineEdited.displayedStyle==6 && !offlineEdited.pets.visibleOwners.isEmpty}
    offlineEdited.systemSuspend()
    defaults.removeObject(forKey:"account-companion-style:"+account)
    let paused=V2ClientModel(profile:profile,endpointOverride:endpoint)
    paused.setFriendInteractionEnabled(false)
    defer{paused.systemSuspend()}
    try await until("legacy appearance restores with social interaction off"){paused.initialAppearanceReady && paused.displayedStyle==7 && !paused.pets.visibleOwners.isEmpty}
    guard !paused.connected else{throw CocoaError(.validationMissingMandatoryProperty)}
    let localProfile=profile+"-local",localSuite="com.fantasyce.petlink."+localProfile
    let localDefaults=UserDefaults(suiteName:localSuite)!
    defer{localDefaults.removePersistentDomain(forName:localSuite)}
    localDefaults.set(false,forKey:"codex-auto-active");localDefaults.set(6,forKey:"local-companion-style")
    let local=V2ClientModel(profile:localProfile,endpointOverride:"http://127.0.0.1:1")
    defer{local.systemSuspend()}
    try await until("signed-out restart keeps local bear"){local.initialAppearanceReady && local.displayedStyle==6 && !local.pets.visibleOwners.isEmpty}
    guard !local.authenticated else{throw CocoaError(.validationMissingMandatoryProperty)}
    print("Appearance recovery PASS")
    exit(0)
   }catch{print("Appearance recovery FAIL: \(error)");exit(1)}
  }
  app.run()
 }
}
