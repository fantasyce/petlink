import AppKit
import Foundation

@main struct V2CredentialRenewalTests {
 @MainActor static func main() {
  let app=NSApplication.shared;app.setActivationPolicy(.accessory)
  Task { @MainActor in
   do {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),profile=CommandLine.arguments[2]
    guard profile.hasPrefix("wake-credential-"),!profile.contains("/"),profile != "default" else{throw CocoaError(.validationMissingMandatoryProperty)}
    let endpoint=try String(contentsOf:root.appendingPathComponent("endpoint"),encoding:.utf8)
    guard let url=URL(string:endpoint),url.scheme=="http",url.host=="127.0.0.1" else{throw URLError(.badURL)}
    for name in [profile,profile+"-peer"] {UserDefaults(suiteName:"com.fantasyce.petlink."+name)!.set(false,forKey:"codex-auto-active")}
    setenv("CODEX_HOME",root.path,1);setenv("CLAUDE_CONFIG_DIR",root.path,1);setenv("DSH_HOME",root.path,1)
    let a=V2ClientModel(profile:profile,endpointOverride:endpoint),b=V2ClientModel(profile:profile+"-peer",endpointOverride:endpoint)
    defer{a.disconnect();b.disconnect();a.pets.hideAll();b.pets.hideAll()}
    func until(_ label:String,_ condition:()->Bool)async throws {
     for _ in 0..<200 {if condition(){print("PASS "+label);return};try await Task.sleep(nanoseconds:50_000_000)}
     throw NSError(domain:"V2CredentialRenewal",code:1,userInfo:[NSLocalizedDescriptionKey:label])
    }
    try await until("isolated native models connected"){a.connected && b.connected && a.snapshot != nil && b.snapshot != nil}
    let hostID=a.snapshot!.selfID,guestID=b.snapshot!.selfID
    guard let host=b.snapshot?.contacts.first(where:{$0.accountID==hostID}) else{throw CocoaError(.fileReadCorruptFile)}
    b.requestVisit(host)
    try await until("visitor displayed only at host"){b.snapshot?.own.phase=="visit" && a.pets.visibleOwners==Set([hostID,guestID]) && b.pets.visibleOwners.isEmpty}
    for (name,modelProfile) in [("self",profile),("peer",profile+"-peer")] {
     guard let old=Vault.read(modelProfile) else{throw CocoaError(.fileReadCorruptFile)}
     try Data().write(to:root.appendingPathComponent("expire-"+name))
     var changed=false
     for _ in 0..<200 {
      guard a.connected && b.connected && b.snapshot?.own.phase=="visit" && a.pets.visibleOwners==Set([hostID,guestID]) && b.pets.visibleOwners.isEmpty else {
       throw NSError(domain:"V2CredentialRenewal",code:2,userInfo:[NSLocalizedDescriptionKey:"\(name) credential expiry interrupted the live visit"])
      }
      if let next=Vault.read(modelProfile),next != old {changed=true;break}
      try await Task.sleep(nanoseconds:50_000_000)
     }
     guard changed else{throw NSError(domain:"V2CredentialRenewal",code:3,userInfo:[NSLocalizedDescriptionKey:"\(name) credential was not renewed"])}
     try await Task.sleep(nanoseconds:300_000_000)
     precondition(a.connected && b.connected && b.snapshot?.own.phase=="visit" && a.pets.visibleOwners==Set([hostID,guestID]),"renewal lost the hosted visitor")
     print("PASS \(name) renewal preserved transport and hosted visitor")
    }
    // The backend commits renewal immediately but holds its HTTP response.
    // Expired panels must hide; a visiting guest must not become a local pet.
    try Data().write(to:root.appendingPathComponent("slow-refresh"))
    for (name,modelProfile) in [("self",profile),("peer",profile+"-peer")] {
     guard let old=Vault.read(modelProfile) else{throw CocoaError(.fileReadCorruptFile)}
     try Data().write(to:root.appendingPathComponent("late-profile"))
     try Data().write(to:root.appendingPathComponent("expire-"+name))
     // Let expiry land before issuing a profile request with the old token.
     try await Task.sleep(nanoseconds:1_200_000_000)
     let staleRequest=Task {await (name=="self" ? a:b).loadProfile()}
     let started=ProcessInfo.processInfo.systemUptime
     var changed=false,sawExpiredLease=false
     for _ in 0..<200 {
      guard a.connected && b.connected && b.snapshot?.own.phase=="visit" && b.pets.visibleOwners.isEmpty else {
       throw NSError(domain:"V2CredentialRenewal",code:4,userInfo:[NSLocalizedDescriptionKey:"slow \(name) renewal duplicated or ended visit"])
      }
      // The host may retain its own offline companion after a display lease
      // lapses; only the visiting guest must have no local fallback.
      let allowed:Set<String>=[hostID,guestID,a.localOwnerID]
      guard a.pets.visibleOwners.isSubset(of:allowed) else{throw NSError(domain:"V2CredentialRenewal",code:5,userInfo:[NSLocalizedDescriptionKey:"slow renewal created a local fallback duplicate"])}
      if name=="self",a.localActive {
       guard !a.pets.visibleOwners.contains(guestID) else{throw NSError(domain:"V2CredentialRenewal",code:7,userInfo:[NSLocalizedDescriptionKey:"visitor remained displayed after lease expiry"])}
       sawExpiredLease=true
      }
      if name=="peer",b.localActive {sawExpiredLease=true}
      if let next=Vault.read(modelProfile),next != old {changed=true;break}
      try await Task.sleep(nanoseconds:50_000_000)
     }
     guard changed,sawExpiredLease,ProcessInfo.processInfo.systemUptime-started>2 else{throw CocoaError(.validationMissingMandatoryProperty)}
     await staleRequest.value
     try await until("slow \(name) renewal restores valid visitor panels"){a.pets.visibleOwners==[hostID,guestID] && b.pets.visibleOwners.isEmpty}
     try FileManager.default.removeItem(at:root.appendingPathComponent("late-profile"))
    }
    let statsData=try Data(contentsOf:root.appendingPathComponent("stats.json"))
    let stats=try JSONSerialization.jsonObject(with:statsData) as! [String:Any]
    guard stats["credential_rotations"] as? Int==4 else{throw NSError(domain:"V2CredentialRenewal",code:6,userInfo:[NSLocalizedDescriptionKey:"duplicate controls or late HTTP 401 rotated credentials twice"])}
    print("PASS delayed post-commit refresh, late HTTP 401 and repeated controls use one rotation per side")
    b.systemSuspend()
    try await until("real disconnect still ends the visit"){a.pets.visibleOwners==[hostID]}
    print("Native credential renewal: host and guest expiry, unchanged visit, no duplicate local pet and genuine disconnect recall PASS")
    exit(0)
   }catch{print("Native credential renewal FAIL: \(error)");exit(1)}
  }
  app.run()
 }
}
