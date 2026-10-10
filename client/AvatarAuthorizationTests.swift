import Foundation
import Security

@main struct AvatarAuthorizationTests {
 final class Store:AvatarIdentityStore {
  var data:Data?;var reads=0;var writes=0;var denied=false
  func read(service:String,account:String)throws->Data? {reads+=1;if denied{throw NSError(domain:NSOSStatusErrorDomain,code:Int(errSecUserCanceled))};return data}
  func write(_ data:Data,service:String,account:String)throws {writes+=1;self.data=data}
  func delete(service:String,account:String){data=nil}
 }
 @MainActor static func main()async throws {
  let suite="avatar-consent-test-"+UUID().uuidString.lowercased()
  let defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  if CommandLine.arguments.contains("--missing") {
   defaults.set(true,forKey:"avatar-authorization-v1.missing.device-a")
   let lost=Store()
   var registered=0
   let recovery=AvatarAuthorization(profile:"missing-test",deviceID:"device-a",defaults:defaults,store:lost,register:{_,_ in registered+=1})
   recovery.setAccount("missing")
   await recovery.prepare(explicit:true)
   precondition(!recovery.isReady && !recovery.isBusy && lost.writes==0 && registered==0 && !recovery.message.isEmpty,"missing previously authorized keys must be explained before generating a replacement")
   await recovery.prepare()
   precondition(lost.writes==0 && registered==0,"background work must not recover a missing key")
   await recovery.prepare(explicit:true)
   precondition(recovery.isReady && lost.writes==1 && registered==1,"a separate explicit recovery action may prepare a replacement")
   print("Avatar missing-key recovery: explanation before replacement PASS")
   return
  }
  let store=Store()
  var registrations:[String]=[]
  let auth=AvatarAuthorization(profile:"consent-test",deviceID:"device-a",defaults:defaults,store:store,register:{account,identity in registrations.append(account)})
  auth.setAccount("alice")
  await auth.prepare()
  precondition(store.reads==0 && store.writes==0 && registrations.isEmpty && auth.identity==nil,"entering before consent must not touch Keychain")
  await auth.prepare(explicit:true)
  precondition(auth.isReady && auth.hasConsent && store.writes==1 && registrations==["alice"],"the user can authorize without any ready friends")
  let first=auth.identity!.agreementPublicKey
  await auth.prepare(explicit:true)
  precondition(store.writes==1 && registrations.count==1,"duplicate clicks must not register again")
  let restarted=AvatarAuthorization(profile:"consent-test",deviceID:"device-a",defaults:defaults,store:store,register:{account,identity in registrations.append(account)})
  restarted.setAccount("alice")
  precondition(restarted.hasConsent && restarted.identity==nil,"restart restores consent without a Keychain read at login")
  let beforeRestore=store.reads
  await restarted.prepare()
  precondition(!restarted.isReady && restarted.identity==nil && store.reads==beforeRestore && registrations.count==1,"restored consent must not trigger Keychain access from page entry or background work")
  await restarted.prepare(explicit:true)
  precondition(restarted.isReady && restarted.identity?.agreementPublicKey==first && store.writes==1,"entering again reuses the saved identity")
  restarted.setAccount("bob")
  let before=store.reads
  await restarted.prepare()
  precondition(!restarted.hasConsent && restarted.identity==nil && store.reads==before,"changing accounts must not inherit authorization")
  let otherDevice=AvatarAuthorization(profile:"consent-test",deviceID:"device-b",defaults:defaults,store:store,register:{_,_ in})
  otherDevice.setAccount("alice")
  await otherDevice.prepare()
  precondition(!otherDevice.hasConsent && store.reads==before,"another device must not inherit authorization")
  let denied=Store();denied.denied=true
  let retry=AvatarAuthorization(profile:"denied-test",deviceID:"device-a",defaults:defaults,store:denied,register:{_,_ in precondition(denied.data != nil)})
  retry.setAccount("denied")
  await retry.prepare(explicit:true)
  precondition(!retry.hasConsent && retry.identity==nil && !retry.isBusy && denied.writes==0,"cancelling Keychain must not enable the feature")
  denied.denied=false
  await retry.prepare(explicit:true)
  precondition(retry.isReady && denied.writes==1,"a cancelled authorization can be retried")
  let resumedStore=Store();resumedStore.data=store.data;resumedStore.denied=true
  let resumed=AvatarAuthorization(profile:"resumed-test",deviceID:"device-a",defaults:defaults,store:resumedStore,register:{_,_ in})
  resumed.setAccount("alice")
  await resumed.prepare(explicit:true)
  precondition(resumed.hasConsent && !resumed.isReady && !resumed.isBusy && resumedStore.writes==0,"cancelled system verification preserves old consent and saved keys")
  let cancelledReads=resumedStore.reads
  await resumed.prepare()
  precondition(resumedStore.reads==cancelledReads,"background snapshots cannot repeat a cancelled system verification")
  resumedStore.denied=false
  await resumed.prepare(explicit:true)
  precondition(resumed.isReady && resumedStore.writes==0 && resumed.identity?.agreementPublicKey==first,"retry after cancelled verification reuses the original key")
  var failRegistration=true
  let saved=Store()
  let networkRetry=AvatarAuthorization(profile:"retry-test",deviceID:"device-a",defaults:defaults,store:saved,register:{_,_ in if failRegistration{throw URLError(.notConnectedToInternet)}})
  networkRetry.setAccount("offline")
  await networkRetry.prepare(explicit:true)
  precondition(networkRetry.hasConsent && !networkRetry.isReady && !networkRetry.isBusy && networkRetry.identity==nil,"a failed registration must not expose a usable identity")
  let savedPublic=try AvatarIdentityVault.decode(saved.data!).agreementPublicKey
  failRegistration=false
  await networkRetry.prepare(explicit:true)
  precondition(networkRetry.isReady && networkRetry.identity?.agreementPublicKey==savedPublic && saved.writes==1,"network retry must reuse the persisted identity")
  // Logout while registration is suspended must discard the late success.
  var waiting:CheckedContinuation<Void,Never>?
  let stale=AvatarAuthorization(profile:"stale-test",deviceID:"device-a",defaults:defaults,store:Store(),register:{_,_ in await withCheckedContinuation{waiting=$0}})
  stale.setAccount("old")
  let pending=Task{@MainActor in await stale.prepare(explicit:true)}
  while waiting==nil{await Task.yield()}
  stale.setAccount("new")
  waiting!.resume()
  await pending.value
  precondition(stale.identity==nil && !stale.isReady && !stale.hasConsent,"a late registration cannot authorize another account")
  print("Avatar authorization: consent boundary / independent activation / persistent identity / cancel / retry / account and device isolation / stale response PASS")
 }
}
