import Combine
import Foundation

@MainActor final class AvatarAuthorization:ObservableObject {
 enum Phase:Equatable {case needsAuthorization,missingIdentity,preparing,registering,ready,failed(String)}
 @Published private(set) var phase:Phase = .needsAuthorization
 @Published private(set) var hasConsent=false
 private(set) var identity:AvatarDeviceIdentity?
 var isReady:Bool{phase == .ready}
 var isBusy:Bool{phase == .preparing || phase == .registering}
 var onReady:(()->Void)?
 private let profile:String,deviceID:String,defaults:UserDefaults,store:any AvatarIdentityStore
 private let register:(String,AvatarDeviceIdentity)async throws->Void
 private let loader=AvatarIdentityLoader()
 private var account:String?,generation=0,work:Task<Void,Never>?
 private func consentKey(_ account:String)->String{"avatar-authorization-v1."+account+"."+deviceID}
 var actionTitle:String {
  if isBusy{return L10n.text("正在准备…")}
  if phase == .missingIdentity{return L10n.text("重新授权")}
  if case .failed=phase{return hasConsent ? L10n.text("重试"):L10n.text("授权")}
  return hasConsent ? L10n.text("继续使用"):L10n.text("授权")
 }
 var message:String {
  switch phase {
  case .needsAuthorization:return ""
  case .missingIdentity:return L10n.text("本机密钥未找到。重新授权会生成新密钥，之前的加密消息将无法解密。")
  case .preparing:return L10n.text("正在准备密钥，请完成可能出现的系统验证…")
  case .registering:return L10n.text("密钥已保存在本机，正在连接数字分身…")
  case .ready:return ""
  case .failed(let message):return message
  }
 }
 init(profile:String,deviceID:String,defaults:UserDefaults,store:any AvatarIdentityStore=AvatarKeychainIdentityStore(),register:@escaping(String,AvatarDeviceIdentity)async throws->Void){
  self.profile=profile;self.deviceID=deviceID;self.defaults=defaults;self.store=store;self.register=register
 }
 // Historical consent is not permission to open system UI after an update.
 // Every vault load starts from the authorization/continue button.
 func setAccount(_ account:String?){
  generation+=1;work?.cancel();work=nil;self.account=account;identity=nil;phase = .needsAuthorization
  hasConsent=account.map{defaults.bool(forKey:consentKey($0))} ?? false
 }
 func prepare(explicit:Bool=false)async {
  guard explicit,let account,!isReady else{return}
  if let work{await work.value;return}
  let epoch=generation
  let createIfMissing = !hasConsent || phase == .missingIdentity
  phase = .preparing
  let task=Task { @MainActor in
   defer{if generation==epoch{work=nil}}
   do {
    let loaded=try await loader.load(profile:profile,store:store,createIfMissing:createIfMissing)
    guard generation==epoch,self.account==account,!Task.isCancelled else{return}
    // Persist consent only after the vault has successfully read back the key.
    // A network retry then reuses the same saved identity.
    defaults.set(true,forKey:consentKey(account));hasConsent=true;phase = .registering
    try await register(account,loaded)
    guard generation==epoch,self.account==account,!Task.isCancelled else{return}
    identity=loaded;phase = .ready;onReady?()
   } catch {
    guard generation==epoch,self.account==account,!Task.isCancelled else{return}
    identity=nil
    let osError=error as NSError
    if let identityError=error as? AvatarIdentityError,identityError == .missing {
     phase = .missingIdentity
    } else if osError.domain==NSOSStatusErrorDomain && osError.code == -128 {
     phase = .failed(L10n.text("已取消系统验证。准备好后可以再次授权。"))
    } else if hasConsent {
     phase = .failed(L10n.text("数字分身暂未连接，点击重试。已保存的密钥不会被替换。"))
    } else {
     phase = .failed(L10n.text("密钥未能保存，请再次授权并完成系统验证。"))
    }
   }
  }
  work=task
  await task.value
 }
}
