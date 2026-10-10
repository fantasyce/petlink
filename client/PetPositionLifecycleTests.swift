import AppKit
import SwiftUI

@main struct PetPositionLifecycleTests {
 @MainActor static func main()async throws {
  let suite="com.fantasyce.petlink.position-lifecycle-tests."+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defaults.set(false,forKey:"codex-auto-active")
  defer{defaults.removePersistentDomain(forName:suite)}
  setenv("CODEX_HOME",URL(fileURLWithPath:CommandLine.arguments[1]).path,1)
  PencilFont.register(resources:URL(fileURLWithPath:"client/Resources",isDirectory:true))
  let screen=PetScreen.connected.first!,positionProfile="startup-position-test"
  let positions=PetPositionStore(defaults:defaults,profile:positionProfile)
  let firstOrigin=NSPoint(x:screen.bounds.minX+50,y:screen.bounds.minY+60)
  let secondOrigin=NSPoint(x:screen.bounds.minX+250,y:screen.bounds.minY+100)
  positions.save(owner:"account-a",origin:firstOrigin,screen:screen)
  positions.save(owner:"account-b",origin:secondOrigin,screen:screen)
  let startup=PetWindows(profile:positionProfile,defaults:defaults,conversation:CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:URL(fileURLWithPath:CommandLine.arguments[1]),listing:{[]},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]})))
  let offline=Pet(owner:"local-startup",name:"",location:"local-startup",target:"",phase:"home",revision:0,style:6,wave:0)
  startup.update([offline],selfID:offline.owner,selfPositionOwner:"account-a")
  precondition(startup.frame(offline.owner)?.origin==firstOrigin,"the first visible offline pet must use the account's saved position")
  let firstFrame=startup.frame(offline.owner)
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(startup.frame(offline.owner)==firstFrame,"the first SwiftUI layout must not move the restored pet")
  let online=Pet(owner:"account-a",name:"QA",location:"account-a",target:"",phase:"home",revision:1,style:6,wave:0)
  startup.update([online],selfID:online.owner)
  precondition(startup.frame(online.owner)?.origin==firstOrigin,"the first online snapshot must not move the companion")
  startup.update([offline],selfID:offline.owner,selfPositionOwner:"account-b")
  precondition(startup.frame(offline.owner)?.origin==secondOrigin,"a reused offline panel must restore the newly selected account before showing")
  NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:NSApplication.shared)
  await Task.yield()
  precondition(startup.frame(offline.owner)?.origin==secondOrigin,"display changes must restore through the same account identity")
  startup.recoverAll()
  precondition(positions.load(owner:"account-b")==startup.frame(offline.owner)?.origin,"moving the offline companion must save the account's position")
  precondition(positions.load(owner:"local-startup")==nil,"the temporary offline identity must not acquire a competing position record")
  startup.hideAll()
  print("Pet startup position: first offline frame, online handoff, account switch, display changes and persistence PASS")
 }
}
