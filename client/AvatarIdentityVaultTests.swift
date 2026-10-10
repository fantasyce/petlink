import Foundation

@main struct AvatarIdentityVaultTests {
 final class MemoryStore:AvatarIdentityStore {
  var values:[String:Data]=[:]
  func read(service:String,account:String)throws->Data?{values[service+"\u{0}"+account]}
  func write(_ data:Data,service:String,account:String)throws{values[service+"\u{0}"+account]=data}
  func delete(service:String,account:String){values.removeValue(forKey:service+"\u{0}"+account)}
 }
 static func main() async throws{
  let identity=AvatarDeviceIdentity.generate()
  let encoded=try AvatarIdentityVault.encode(identity)
  let decoded=try AvatarIdentityVault.decode(encoded)
  assert(decoded.agreementPublicKey==identity.agreementPublicKey)
  assert(decoded.signingPublicKey==identity.signingPublicKey)

  let profile="avatar-vault-"+UUID().uuidString.lowercased()
  let store=MemoryStore()
  defer{AvatarIdentityVault.delete(profile:profile,store:store)}
  let first=try AvatarIdentityVault.loadOrCreate(profile:profile,store:store)
  let second=try AvatarIdentityVault.loadOrCreate(profile:profile,store:store)
  assert(first.agreementPublicKey==second.agreementPublicKey)
  assert(first.signingPublicKey==second.signingPublicKey)
  AvatarIdentityVault.delete(profile:profile,store:store)
  assert(AvatarIdentityVault.read(profile:profile,store:store)==nil)
  let blocked=BlockingStore(data:encoded)
  let loader=AvatarIdentityLoader()
  let load=Task { @MainActor in try await loader.load(profile:profile,store:blocked) }
  while !blocked.hasEntered() {try await Task.sleep(nanoseconds:1_000_000)}
  let secondLoad=Task {try await loader.load(profile:profile,store:blocked)}
  // This main-actor work must run while the Security boundary is blocked.
  await MainActor.run { _ = blocked.release.signal() }
  let loaded=try await load.value
  let concurrent=try await secondLoad.value
  assert(loaded.signingPublicKey==concurrent.signingPublicKey)
  assert(blocked.reads==1)
  print("Avatar identity vault: serialization / memory-store stability / nonblocking single-flight PASS")
 }
 final class BlockingStore:AvatarIdentityStore {
  let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
  let data:Data;var reads=0
  init(data:Data){self.data=data}
  func hasEntered()->Bool{entered.wait(timeout:.now()) == .success}
  func read(service:String,account:String)throws->Data?{reads+=1;entered.signal();_ = release.wait(timeout:.now()+5);return data}
  func write(_ data:Data,service:String,account:String)throws{fatalError("existing identity must not be replaced")}
  func delete(service:String,account:String){fatalError("must not delete identity")}
 }
}
