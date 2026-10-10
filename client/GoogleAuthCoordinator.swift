import Foundation
import Combine

enum GoogleAuthMode:String {case login,link}
enum GoogleAuthState:Equatable {case idle,listening,authorizing,exchanging,confirmLink,confirmTakeover,completed,failed}

@MainActor final class GoogleAuthCoordinator:ObservableObject {
 typealias Request = @MainActor (String,[String:Any]?,String?) async throws -> Data
 typealias OpenBrowser = @MainActor (URL)->Bool
 @Published private(set) var state:GoogleAuthState = .idle
 @Published private(set) var notice=""
 @Published private(set) var pending:GoogleLoginResponse?
 @Published var nickname=""
 @Published var migrating=false
 @Published var legacyUsername=""
 @Published var legacyPassword=""
 @Published var legacyRecovery=""
 @Published var legacyAccessToken:String?
 private let deviceID:String
 private let request:Request
 private let openBrowser:OpenBrowser
 private let closeBrowser:()->Void
 private let onSession:(GoogleLoginResponse)->Void
 private var listener:GoogleLoopback?
 private var epoch=0
 private var attemptToken:String?
 var busy:Bool{[.listening,.authorizing,.exchanging].contains(state)}
 init(deviceID:String,request:@escaping Request,openBrowser:@escaping OpenBrowser,closeBrowser:@escaping()->Void = {},onSession:@escaping(GoogleLoginResponse)->Void){self.deviceID=deviceID;self.request=request;self.openBrowser=openBrowser;self.closeBrowser=closeBrowser;self.onSession=onSession}
 func cancel(){
  epoch+=1;listener?.cancel();listener=nil;pending=nil;state = .idle;notice=L10n.text("已取消登录")
  closeBrowser()
  if let token=attemptToken{attemptToken=nil;Task{_ = try? await request("google/cancel",["attempt_token":token],nil)}}
 }
 func selectMode(_ mode:GoogleAuthMode,legacyToken:String?=nil){
  cancel();migrating = mode == .link
  legacyAccessToken=migrating ? legacyToken:nil
  legacyUsername="";legacyPassword="";legacyRecovery="";notice=""
 }
 func start(mode:GoogleAuthMode)async{
  guard !busy,state != .confirmLink,state != .confirmTakeover else{return}
  migrating = mode == .link
  epoch+=1;let current=epoch;state = .listening;notice=L10n.text("正在准备 Google 登录…");pending=nil
  do{
   let config=try JSONDecoder().decode(GoogleAuthConfig.self,from:await request("config",nil,nil))
   guard current==epoch else{return}
   guard config.mode=="google",config.authProtocol==1,!config.clientID.isEmpty else{throw GoogleAuthError.invalidResponse}
   var migration:String?
   if mode == .link {
    guard config.migrationOpen else{throw GoogleAuthError.server("MIGRATION_CLOSED")}
    if legacyAccessToken==nil {
     let proof=try JSONDecoder().decode(GoogleLoginResponse.self,from:await request("migration/prove",["username":legacyUsername,"password":legacyPassword,"recovery_code":legacyRecovery,"device_id":deviceID],nil))
     guard let ticket=proof.ticket else{throw GoogleAuthError.invalidResponse};migration=ticket
    }
   }
   guard current==epoch else{return}
   let verifier=try GooglePKCE.random(),stateValue=try GooglePKCE.random()
   let local=GoogleLoopback();listener=local;let callback=try await local.start(state:stateValue)
   guard current==epoch else{local.cancel();return}
   var body:[String:Any]=["device_id":deviceID,"challenge":GooglePKCE.challenge(verifier),"redirect_uri":callback.absoluteString,"mode":mode.rawValue]
   if let migration{body["migration_ticket"]=migration}
   let begun=try JSONDecoder().decode(GoogleBeginResponse.self,from:await request("google/begin",body,mode == .link ? legacyAccessToken:nil))
   guard current==epoch else{local.cancel();_ = try? await request("google/cancel",["attempt_token":begun.attemptToken],nil);return}
   guard begun.clientID==config.clientID,!begun.nonce.isEmpty,!begun.attemptToken.isEmpty else{throw GoogleAuthError.invalidResponse}
   attemptToken=begun.attemptToken
   var auth=URLComponents(string:"https://accounts.google.com/o/oauth2/v2/auth")!
   auth.queryItems=["client_id":begun.clientID,"redirect_uri":callback.absoluteString,"response_type":"code","scope":"openid email","state":stateValue,"nonce":begun.nonce,"code_challenge":GooglePKCE.challenge(verifier),"code_challenge_method":"S256","prompt":"select_account"].map{URLQueryItem(name:$0.key,value:$0.value)}
   guard let url=auth.url,openBrowser(url) else{throw GoogleAuthError.listenerFailed}
   state = .authorizing;notice=L10n.text("请在浏览器完成 Google 登录")
   let code=try await local.waitForCode();guard current==epoch else{return}
   closeBrowser()
   listener=nil;state = .exchanging;notice=L10n.text("正在验证身份…")
   let result=try JSONDecoder().decode(GoogleLoginResponse.self,from:await request("google/complete",["attempt_token":begun.attemptToken,"code":code,"verifier":verifier],nil))
   guard current==epoch else{return};attemptToken=nil;legacyPassword="";legacyRecovery="";accept(result)
  }catch{
   guard current==epoch else{return};listener?.cancel();listener=nil
   closeBrowser()
   if mode == .link,case GoogleAuthError.server("UNAUTHORIZED") = error {legacyAccessToken=nil}
   if let token=attemptToken{attemptToken=nil;_ = try? await request("google/cancel",["attempt_token":token],nil)}
   guard current==epoch else{return};state = .failed;notice=Self.message(error)
  }
 }
 func confirm()async{
  guard let p=pending,let ticket=p.ticket,state == .confirmLink||state == .confirmTakeover else{return}
  let path=state == .confirmLink ? "google/link-confirm":"google/takeover"
  let current=epoch;state = .exchanging;notice=L10n.text("正在确认…")
  do{let result=try JSONDecoder().decode(GoogleLoginResponse.self,from:await request(path,["ticket":ticket,"device_id":deviceID],nil));guard current==epoch else{return};accept(result)}catch{guard current==epoch else{return};pending=nil;state = .failed;notice=Self.message(error)}
 }
 private func accept(_ result:GoogleLoginResponse){
  pending=result
  if result.status=="link_confirmation",result.ticket != nil{state = .confirmLink;notice=L10n.text("请核对旧账号与 Google 账号，确认后绑定");return}
  if result.status=="takeover_required",result.ticket != nil{state = .confirmTakeover;notice=L10n.text("此账号正在另一台设备使用，是否接管？");return}
  guard let access=result.accessToken,!access.isEmpty,let refresh=result.refreshToken,!refresh.isEmpty,let account=result.accountID,!account.isEmpty,let friend=result.friendID,!friend.isEmpty else{state = .failed;notice=L10n.text("登录响应不完整，请重新登录");return}
  notice=L10n.text("身份验证完成，正在连接 PetLink…");pending=nil;onSession(result);state = .completed
 }
 static func message(_ error:Error)->String{
  if let e=error as? URLError {
   if e.code == .timedOut {return L10n.text("连接登录服务超时，请稍后重试")}
   return L10n.text("无法连接登录服务，请稍后重试")
  }
  guard let e=error as? GoogleAuthError else{return L10n.text("登录未完成，请检查网络后重试")}
  switch e{
  case .cancelled:return L10n.text("已取消登录")
  case .denied:return L10n.text("你已取消 Google 授权，可以重新登录")
  case .expired:return L10n.text("登录已过期，请重新开始")
  case .invalidCallback:return L10n.text("登录回调无效，请重新开始")
  case .listenerFailed:return L10n.text("无法启动本机登录回调，请重试")
  case .invalidEndpoint:return L10n.text("此中控地址未获信任，不能发送登录信息")
  case .serviceUnavailable:return L10n.text("登录服务尚未就绪，请稍后重试")
  case .invalidResponse:return L10n.text("登录配置不匹配，请更新客户端或联系支持")
  case .server(let code):
   return ["GOOGLE_UNAVAILABLE":L10n.text("暂时无法连接 Google，请稍后重试"),"GOOGLE_LOGIN_EXPIRED":L10n.text("登录已过期，请重新开始"),"AUTH_ATTEMPT_USED":L10n.text("这次登录已处理，请重新开始"),"AUTH_RATE_LIMITED":L10n.text("尝试过于频繁，请稍后重试"),"GOOGLE_ALREADY_LINKED":L10n.text("此 Google 账号已绑定其他 PetLink 账号"),"ACCOUNT_ALREADY_LINKED":L10n.text("旧账号已完成绑定，请使用 Google 登录"),"MIGRATION_CLOSED":L10n.text("旧账号迁移已关闭，请联系支持"),"MIGRATION_REQUIRED":L10n.text("请先迁移旧账号"),"UNAUTHORIZED":L10n.text("旧账号验证失败，请检查登录信息"),"VALIDATION_FAILED":L10n.text("请检查昵称和输入内容后重试"),"CLIENT_UPGRADE_REQUIRED":L10n.text("请更新 PetLink 后再登录")][code] ?? L10n.text("登录未完成，请重试或联系支持")
  }
 }
}
