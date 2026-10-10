import Foundation

@main struct VaultTests {
 static func main()async throws {
  let fake=BlockingSessionStore(),io=SessionPersistence(store:fake)
  let first=io.write("old",profile:"test")
  while !fake.started(){try await Task.sleep(nanoseconds:1_000_000)}
  let deletion=io.delete(profile:"test")
  let newest=io.write("new",profile:"test")
  await MainActor.run{_ = fake.release.signal()}
  _ = try await first.value;_ = try await deletion.value;_ = try await newest.value
  let read=try await io.read(profile:"test").value
  assert(read=="new","old write or logout overwrote latest login")
  let profile="qa-vault-"+UUID().uuidString.lowercased()
  let url=try Vault.fileURL(profile)
  defer {try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}
  try Vault.writePrivateFile("test-fixture-not-a-live-credential",profile:profile)
  assert(Vault.readPrivateFile(profile)=="test-fixture-not-a-live-credential")
  let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
  assert((attrs[.posixPermissions] as? NSNumber)?.intValue==0o600)
  let saved=try Vault.write("replacement-fixture",profile:profile);assert(saved)
  assert(Vault.readPrivateFile(profile)=="replacement-fixture")
  assert(Vault.read(profile)=="replacement-fixture")
  Vault.delete(profile);assert(Vault.readPrivateFile(profile)==nil)
  assert(Vault.usesPrivateFile(profile),"logout must retain a tombstone to prevent old keychain fallback")
  assert(Vault.read(profile)==nil)
  try Vault.writePrivateFile("permission-fixture",profile:profile)
  try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:url.path)
  assert(Vault.readPrivateFile(profile)==nil)
  do {_=try Vault.fileURL("../escape");fatalError("unsafe profile accepted")}catch{}
  print("Vault: private permissions, roundtrip, atomic replace, unsafe mode/path rejection PASS")
 }
 final class BlockingSessionStore:SessionStore {
  var value:String?;let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
  func started()->Bool{entered.wait(timeout:.now()) == .success}
  func read(_ profile:String)->String?{value}
  func write(_ value:String,profile:String)throws->Bool{if value=="old"{entered.signal();_ = release.wait(timeout:.now()+5)};self.value=value;return true}
  func delete(_ profile:String){value=nil}
 }
}
