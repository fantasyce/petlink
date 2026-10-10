import AppKit
import Foundation

@main struct NativeTests {
 @MainActor static func main(){
  let app=NSApplication.shared
  app.setActivationPolicy(.accessory)
  Task { @MainActor in
   do {
    let env=ProcessInfo.processInfo.environment
    guard let base=env["PETLINK_TEST_URL"],let dir=env["PETLINK_TEST_INVITES"] else{throw NSError(domain:"fixture",code:1)}
    let ta=try String(contentsOfFile:dir+"/token-a.txt",encoding:.utf8)
    let tb=try String(contentsOfFile:dir+"/token-b.txt",encoding:.utf8)
    let a=ClientModel(profile:"qa-a",endpointOverride:base,tokenOverride:ta)
    let b=ClientModel(profile:"qa-b",endpointOverride:base,tokenOverride:tb)
    defer {a.disconnect();b.disconnect();UserDefaults.standard.removePersistentDomain(forName:"com.fantasyce.petlink.qa-a");UserDefaults.standard.removePersistentDomain(forName:"com.fantasyce.petlink.qa-b")}
    @MainActor func until(_ label:String,_ predicate:()->Bool) async throws {
     for _ in 0..<100 {if predicate(){print("PASS "+label);return};try await Task.sleep(nanoseconds:200_000_000)}
     throw NSError(domain:"NativeJourney",code:1,userInfo:[NSLocalizedDescriptionKey:label+" timeout: A="+a.message+" B="+b.message])
    }
    try await until("native connect"){a.connected&&b.connected}
    a.send("recall");b.send("recall")
    try await until("real NSPanel home"){a.pets.visibleOwners==["a"]&&b.pets.visibleOwners==["b"]}
    b.send("allow",fields:["peer":"a","enabled":true])
    try await until("native grant"){a.snapshot?.friends.first?.canVisit==true}
    a.send("visit",fields:["peer":"b"])
    try await until("native departure and arrival"){a.pets.visibleOwners.isEmpty&&b.pets.visibleOwners==["a","b"]}
    if let visitor=b.pets.frame("a"),let host=b.pets.frame("b"),visitor.intersects(host){throw NSError(domain:"NativeJourney",code:2,userInfo:[NSLocalizedDescriptionKey:"visitor is obscured by host panel"])}
    a.send("style",fields:["style":1]);a.send("wave")
    try await until("native outfit relay"){b.snapshot?.pets.contains{$0.owner=="a"&&$0.style==1}==true}
    a.send("recall")
    try await until("native recall"){a.pets.visibleOwners==["a"]&&b.pets.visibleOwners==["b"]}
    a.send("visit",fields:["peer":"b"])
    try await until("native revisit"){b.pets.visibleOwners==["a","b"]&&a.pets.visibleOwners.isEmpty}
    b.suspend()
    guard b.pets.visibleOwners.isEmpty else{throw NSError(domain:"sleep did not hide",code:1)}
    b.systemSuspend();b.systemResume()
    guard b.paused && !b.connected else{throw NSError(domain:"system wake cleared user pause",code:1)}
    try await until("native host disconnect recovers owner"){a.pets.visibleOwners==["a"]}
    b.resume()
    try await until("native resume"){b.connected&&b.pets.visibleOwners==["b"]}
    b.send("allow",fields:["peer":"a","enabled":false])
    try await until("native revoke"){a.snapshot?.friends.first?.canVisit==false}
    print("NATIVE_JOURNEY_PASS (programmatic model + AppKit windows; not manual UI control acceptance)")
    exit(0)
   }catch{print("NATIVE_JOURNEY_FAIL \(error)");exit(1)}
  }
  app.run()
 }
}
