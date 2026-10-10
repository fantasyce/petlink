import AppKit
import Foundation
import Security

@MainActor final class V2ClientModel:ObservableObject {
 @Published var endpoint:String{didSet{if endpoint != oldValue{googleAuth.cancel()}}};@Published var invite="";@Published var username="";@Published var password="";@Published var nickname="";@Published var recoveryInput="";@Published var friendIDInput=""
 @Published var nicknameDraft=""
 @Published var editingNickname=false
 @Published var savingNickname=false
 @Published var nicknameNotice=""
 @Published private(set) var avatarProviderReports:[String:AvatarCapabilityReport]=[:]
 @Published private(set) var avatarProviderChecking=false
 private var avatarProviderRefresh=AvatarProviderRefresh()
 @Published var migrationRequired=false
 @Published private(set) var localStyle=8
 @Published private(set) var localWave:Int64=0
 @Published private(set) var localActive=true
 @Published private(set) var initialAppearanceReady=false
 private var localCompanion:LocalCompanion!
 private var renderedLocalStyle:Int?
 var localMode:Bool{localActive || !connected}
 var displayedStyle:Int{localMode ? localStyle:(snapshot?.own.style ?? localStyle)}
 var displayedAtHome:Bool{localMode || snapshot?.own.phase=="home"}
 var displayedWave:Int64{localMode ? localWave:(snapshot?.own.waveSequence ?? 0)}
 var localOwnerID:String{"local-"+profile}
 func updateLocalCompanion(){
  guard initialAppearanceReady,localMode,!systemSuspended else{return}
  // A transport that is renewing may temporarily lose its display lease.
  // The visiting own pet stays hidden until an authorized snapshot returns.
  if connected,snapshot?.own.phase != "home" {pets.hideAll();return}
  guard pets.visibleOwners != Set([localOwnerID]) || renderedLocalStyle != localStyle else{return}
  renderedLocalStyle=localStyle
  pets.update([Pet(owner:localOwnerID,name:"",location:localOwnerID,target:"",phase:"home",revision:0,style:localStyle,wave:localWave)],selfID:localOwnerID,selfPositionOwner:session?.accountID)
 }
 func waveCompanion(){guard initialAppearanceReady else{return};if localMode{localWave+=1;pets.wave(localOwnerID)}else{send("wave")}}
 func dressCompanion(_ style:Int){guard initialAppearanceReady,(0...9).contains(style) else{return};if let account=session?.accountID{localCompanion.rememberStyle(style,accountID:account)}else{localCompanion.setStyle(style)};localStyle=style;if localMode{updateLocalCompanion()}else{send("style",fields:["style":style])}}
 private func prepareInitialAppearance(){
  pets.hideAll();renderedLocalStyle=nil;localActive=true
  if let account=session?.accountID {
   if let style=localCompanion.savedStyle(accountID:account){localStyle=style;initialAppearanceReady=true}else{initialAppearanceReady=false}
  }else{localStyle=localCompanion.style;initialAppearanceReady=true}
  updateLocalCompanion()
 }
 @Published var openOutfitRequested=false
 @Published var googleEmail=""
 private let googleTransport=GoogleAuthTransport()
 private var migrationNeedsProof=false
 var returnFromGoogle:(()->Void)?
 private lazy var googleBrowser:GoogleAuthBrowser = GoogleAuthBrowser(onCancel:{[weak self] in self?.googleAuth.cancel()})
 var googleMigrationToken:String?{migrationNeedsProof ? nil:session?.accessToken}
 lazy var googleAuth:GoogleAuthCoordinator = GoogleAuthCoordinator(deviceID:deviceID,request:{[weak self] path,body,token in
  guard let self,let endpoint=self.baseURL() else{throw GoogleAuthError.invalidEndpoint}
  return try await self.googleTransport.request(endpoint:endpoint,profile:self.profile,path:path,body:body,token:token)
 },openBrowser:{[weak self] in self?.googleBrowser.open($0) ?? false},closeBrowser:{[weak self] in self?.googleBrowser.close();self?.returnFromGoogle?()},onSession:{[weak self] result in
  guard let self,let account=result.accountID,let friend=result.friendID,let access=result.accessToken,let refresh=result.refreshToken else{return}
  self.migrationRequired=false;self.adopt(V2AuthResponse(accountID:account,friendID:friend,accessToken:access,refreshToken:refresh,recoveryCode:nil))
  self.selectedTab=0;self.returnFromGoogle?()
 })
 func startGoogleLogin(){Task{await googleAuth.start(mode:.login)}}
 func startGoogleLink(){Task{await googleAuth.start(mode:.link)}}
 @Published var operationNotice=""
 @Published var message=L10n.text("尚未登录");@Published var connected=false;@Published var connecting=false;@Published var busy=false;@Published var recoveryCode="";@Published var credentialWarning="";@Published var profileInfo:V2ProfileDTO?;@Published var snapshot:V2SnapshotDTO?;@Published var accepting=true;@Published var selectedTab=0;@Published var authMode=0;@Published var editingNoteContactID:String?;@Published var noteDraft="";@Published var contactSearch="";@Published var contactFilter=0;@Published private(set) var friendInteractionEnabled=true
 @Published var avatarOwnerNotice=AvatarOwnerNotice()
 @Published var avatarChat=AvatarChatHistory(){didSet{refreshVisitorChats()}};@Published var avatarSubmitting=false;@Published var selectedAvatarOwner=""
 @Published var avatarAuthorizationPresented=false
 @Published private(set) var avatarResponding:Set<String>=[]
 private var pendingAvatarOwner:String?,pendingAvatarApproval:AvatarRelayDTO?
 private var pendingAvatarRemember=false
 var avatarQuestion:String {get{avatarChat.draft(owner:selectedAvatarOwner)}set{avatarChat.setDraft(newValue,owner:selectedAvatarOwner)}}
 let profile:String;let deviceID:String;let pets:PetWindows;var agentCoordinator:AgentCoordinator!
 private let sessionPersistence=SessionPersistence();private var refreshTask:Task<Bool,Never>?
 private var avatarRuns:[String:Task<Void,Never>]=[:]
 private func stopAvatarRuns(){for run in avatarRuns.values{run.cancel()};avatarRuns.removeAll();avatarResponding.removeAll()}
 private var identityEpoch=0
 lazy var avatarAuthorization:AvatarAuthorization = {
  let authorization=AvatarAuthorization(profile:profile,deviceID:deviceID,defaults:defaults,register:{[weak self] account,identity in
   guard let self,self.authenticated,self.session?.accountID==account else{throw CancellationError()}
   let key=try await self.perform("POST","devices/keys",body:["authorize":true,"device_id":self.deviceID,"agreement_public_key":identity.agreementPublicKey,"signing_public_key":identity.signingPublicKey],authenticated:true,version:3,as:AvatarDeviceKeyDTO.self)
   guard key.accountID==account,key.deviceID==self.deviceID,key.agreementPublicKey==identity.agreementPublicKey,key.signingPublicKey==identity.signingPublicKey else{throw AvatarCryptoError.invalidKey}
  })
  authorization.onReady={[weak self] in guard let self else{return};self.refreshAvatarProviders();self.send("sync");self.processAvatarTasks(self.snapshot?.avatarTasks ?? [])}
  return authorization
 }()
 private let defaults:UserDefaults;private let network=URLSession(configuration:.ephemeral);private var session:V2Session?;private(set) var legacyToken:String?;private var socket:URLSessionWebSocketTask?;private var timer:Timer?;private var reconnect:Task<Void,Never>?;private var gate=LeaseGate();private var generation=0;private var ticks=0;private var systemSuspended=false;private var lastWaves:[String:Int64]=[:];private var observers:[NSObjectProtocol]=[];private var handledAvatarTasks:Set<String>=[]
 private var socketAccessToken:String?
 private var socketCredentialRefresh:Task<Void,Never>?
 private var socketRenewalRequestID:String?
 private var socketRenewalAccessToken:String?
 var authenticated:Bool{session != nil && !migrationRequired};var needsClaim:Bool{session==nil&&legacyToken != nil}
 init(profile:String="default",endpointOverride:String?=nil){
  self.profile=profile;defaults=UserDefaults(suiteName:"com.fantasyce.petlink."+profile)!;let resolvedEndpoint=PetLinkEndpoint.resolve(saved:defaults.string(forKey:"endpoint"),override:endpointOverride,profile:profile);endpoint=resolvedEndpoint;if endpointOverride==nil{defaults.set(resolvedEndpoint,forKey:"endpoint")};if let existing=defaults.string(forKey:"device-id"){deviceID=existing}else{deviceID=UUID().uuidString.lowercased();defaults.set(deviceID,forKey:"device-id")};pets=PetWindows(profile:profile,defaults:defaults)
  pets.openVisitorChat={[weak self] owner in guard let self,let contact=self.snapshot?.contacts.first(where:{$0.accountID==owner}),self.canAskAvatar(contact) else{return};self.openAvatarChat(contact);self.returnFromGoogle?()}
  localCompanion=LocalCompanion(defaults:defaults);localStyle=localCompanion.style;message=L10n.text("在家");updateLocalCompanion()
  timer=Timer(timeInterval:0.2,repeats:true){[weak self] _ in Task{@MainActor in self?.tick()}};RunLoop.main.add(timer!,forMode:.common)
  let nc=NSWorkspace.shared.notificationCenter;observers.append(nc.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.systemSuspend()}});observers.append(nc.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.systemResume()}})
  agentCoordinator=AgentCoordinator(profile:profile){[weak self] event in self?.publishAgent(event)}
  agentCoordinator.trackingEnabled=pets.conversation.automaticEnabled
  pets.conversation.claudeStatusChanged={[weak self] found,connected in self?.agentCoordinator.updateClaudeSessions(found,connected:connected)}
  pets.conversation.dshStatusChanged={[weak self] found,connected in self?.agentCoordinator.updateDSHSessions(found,connected:connected)}
  agentCoordinator.versionsChanged={[weak self] in self?.pets.conversation.refreshConnections()}
  pets.conversation.trackingChanged={[weak self] enabled in self?.agentCoordinator.trackingEnabled=enabled}
  agentCoordinator.localStatusChanged = {[weak self] sessions in
   guard let self else{return}
   let summary=sessions.first.map{L10n.text("{0} 个会话 · {1}", sessions.count, agentStateLabel($0.state.rawValue))} ?? ""
   pets.setAgentSummary(summary)
  }
  busy=true
  let epoch=identityEpoch,read=sessionPersistence.read(profile:profile)
  Task { @MainActor in
   defer{if identityEpoch==epoch{busy=false}}
   let stored=try? await read.value
   guard identityEpoch==epoch else{return}
   if let stored, !stored.isEmpty {if let data=stored.data(using:.utf8),let decoded=try? JSONDecoder().decode(V2Session.self,from:data){session=decoded}else{legacyToken=stored}}
   prepareInitialAppearance()
   if authenticated{avatarAuthorization.setAccount(session?.accountID);connect();await loadProfile()}
  }
 }
 private func baseURL()->URL?{guard let u=URL(string:normalizedCredentialPaste(endpoint)),u.user==nil,u.password==nil,u.query==nil,u.fragment==nil,(u.scheme=="https"||(u.scheme=="http"&&["127.0.0.1","localhost"].contains(u.host ?? "")))else{return nil};return u}
 private func apiURL(_ path:String,version:Int=2)->URL?{baseURL()?.appendingPathComponent("v\(version)").appendingPathComponent(path)}
 private func perform<T:Decodable>(_ method:String,_ path:String,body:[String:Any]?=nil,authenticated:Bool=false,tokenOverride:String?=nil,retryAuth:Bool=true,version:Int=2,as type:T.Type)async throws->T{
  let binding=V2RequestBinding(epoch:identityEpoch,accountID:session?.accountID)
  func checkBinding()throws{if authenticated,tokenOverride==nil,!binding.matches(epoch:identityEpoch,accountID:session?.accountID){throw CancellationError()}}
  try checkBinding()
  guard let url=apiURL(path,version:version)else{throw V2APIError(code:"INVALID_ENDPOINT",message:L10n.text("中控地址无效"))}
  var req=URLRequest(url:url);req.httpMethod=method;req.timeoutInterval=15;req.setValue("application/json",forHTTPHeaderField:"Content-Type")
  if method != "GET"{req.setValue(UUID().uuidString,forHTTPHeaderField:"X-Request-ID")}
  let requestToken=tokenOverride ?? session?.accessToken
  if authenticated,let token=requestToken{req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
  if let body{req.httpBody=try JSONSerialization.data(withJSONObject:body)}
  let(data,response)=try await network.data(for:req)
  try checkBinding()
  let status=(response as? HTTPURLResponse)?.statusCode ?? 0
  if status==401,authenticated,tokenOverride==nil,retryAuth {
   var refreshed=requestToken != session?.accessToken
   if !refreshed {refreshed=await refreshSession()}
   try checkBinding()
   if refreshed{return try await perform(method,path,body:body,authenticated:true,retryAuth:false,version:version,as:type)}
  }
  if !(200..<300).contains(status){if let api=try? JSONDecoder().decode(V2APIError.self,from:data){throw api};throw V2APIError(code:"HTTP_\(status)",message:L10n.text("网络请求失败"))}
  return try JSONDecoder.petLink.decode(T.self,from:data)
 }
 private func adopt(_ auth:V2AuthResponse){stopAvatarRuns();avatarSubmitting=false;avatarChat=AvatarChatHistory();selectedAvatarOwner="";cancelAvatarAuthorization();handledAvatarTasks.removeAll();identityEpoch+=1;refreshTask=nil;avatarOwnerNotice=AvatarOwnerNotice();let next=V2Session(accountID:auth.accountID,friendID:auth.friendID,accessToken:auth.accessToken,refreshToken:auth.refreshToken);session=next;snapshot=nil;profileInfo=nil;prepareInitialAppearance();legacyToken=nil;recoveryCode=auth.recoveryCode ?? "";persistSession(next);defaults.set(endpoint,forKey:"endpoint");password="";avatarAuthorization.setAccount(auth.accountID);connect();Task{await loadProfile()}}
 func register(){guard !busy else{return};busy=true;message=L10n.text("正在注册…");let body:[String:Any]=["invite":normalizedCredentialPaste(invite),"username":normalizedCredentialPaste(username),"password":password,"nickname":normalizedCredentialPaste(nickname),"device_id":deviceID,"request_id":UUID().uuidString];Task{defer{busy=false};do{let a=try await perform("POST","auth/register",body:body,as:V2AuthResponse.self);adopt(a);invite="";message=L10n.text("注册成功，请保存恢复码")}catch{message=L10n.text("注册失败：{0}", describe(error))}}}
 func login(takeover:Bool=false){guard !busy else{return};busy=true;message=takeover ? L10n.text("正在接管设备…"):L10n.text("正在登录…");let body:[String:Any]=["username":normalizedCredentialPaste(username),"password":password,"device_id":deviceID];Task{defer{busy=false};do{let a=try await perform("POST",takeover ? "auth/takeover":"auth/login",body:body,as:V2AuthResponse.self);adopt(a);message=L10n.text("登录成功")}catch{message=L10n.text("登录失败：{0}", describe(error))}}}
 func claimLegacy(){guard !busy,let legacyToken else{return};busy=true;message=L10n.text("正在认领原有桌宠…");let body:[String:Any]=["legacy_token":legacyToken,"username":normalizedCredentialPaste(username),"password":password,"nickname":normalizedCredentialPaste(nickname),"device_id":deviceID];Task{defer{busy=false};do{let a=try await perform("POST","auth/claim",body:body,as:V2AuthResponse.self);adopt(a);message=L10n.text("认领成功，请保存恢复码")}catch{message=L10n.text("认领失败：{0}", describe(error))}}}
 func recover(){guard !busy else{return};busy=true;message=L10n.text("正在恢复…");let body:[String:Any]=["username":normalizedCredentialPaste(username),"recovery_code":normalizedCredentialPaste(recoveryInput),"new_password":password,"device_id":deviceID];Task{defer{busy=false};do{let a=try await perform("POST","auth/recover",body:body,as:V2AuthResponse.self);adopt(a);message=L10n.text("恢复成功，请保存新的恢复码")}catch{message=L10n.text("恢复失败：{0}", describe(error))}}}
 private func describe(_ error:Error)->String{(error as? V2APIError)?.code ?? error.localizedDescription}
 func loadProfile()async{guard authenticated else{return};let epoch=identityEpoch;do{let profile=try await perform("GET","me",authenticated:true,as:V2ProfileDTO.self);profileInfo=profile;accepting=profile.accepting;if !initialAppearanceReady,profile.accountID==session?.accountID,let style=profile.style,(0...9).contains(style){localCompanion.rememberStyle(style,accountID:profile.accountID);localStyle=style;initialAppearanceReady=true;updateLocalCompanion()};if let endpoint=baseURL(),let data=try? await googleTransport.request(endpoint:endpoint,profile:self.profile,path:"identity",body:nil,token:session?.accessToken),let identity=try? JSONSerialization.jsonObject(with:data) as? [String:String]{googleEmail=identity["email"] ?? ""}}catch{guard identityEpoch==epoch else{return};if (error as? V2APIError)?.code=="MIGRATION_REQUIRED"{disconnect();migrationRequired=true;message=L10n.text("请绑定 Google 以保留原账号")}else{message=L10n.text("资料加载失败：{0}", describe(error))}}}
 func saveNickname(){
  guard authenticated,!savingNickname else{return}
  let epoch=identityEpoch,draft=nicknameDraft.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !draft.isEmpty,draft.count<=40 else{nicknameNotice=L10n.text("请输入 1–40 个字的昵称");return}
  savingNickname=true;nicknameNotice=""
  Task{defer{savingNickname=false};do{let updated=try await perform("PATCH","me",body:["nickname":draft],authenticated:true,as:V2ProfileDTO.self);guard identityEpoch==epoch else{return};profileInfo=updated;nicknameDraft=updated.nickname;editingNickname=false;nicknameNotice=L10n.text("昵称已更新");send("sync")}catch{guard identityEpoch==epoch else{return};nicknameNotice=L10n.text("昵称保存失败，请重试")}}
 }
 func logout(){stopAvatarRuns();avatarSubmitting=false;avatarChat=AvatarChatHistory();selectedAvatarOwner="";cancelAvatarAuthorization();googleAuth.selectMode(.login);migrationRequired=false;googleEmail="";identityEpoch+=1;avatarAuthorization.setAccount(nil);refreshTask=nil;avatarOwnerNotice=AvatarOwnerNotice();let old=session;disconnect();session=nil;profileInfo=nil;snapshot=nil;prepareInitialAppearance();handledAvatarTasks.removeAll();let deletion=sessionPersistence.delete(profile:profile);busy=true;let epoch=identityEpoch;Task{_ = try? await deletion.value;if identityEpoch==epoch{busy=false;credentialWarning=""}};message=L10n.text("已退出，正在清理本机凭据…");if let old{Task{_ = try? await perform("POST","auth/logout",body:[:],authenticated:true,tokenOverride:old.accessToken,as:OKResponse.self)}}}
 private func persistSession(_ value:V2Session) {
  guard let data=try? JSONEncoder().encode(value),let raw=String(data:data,encoding:.utf8)else{return}
  let epoch=identityEpoch,write=sessionPersistence.write(raw,profile:profile)
  credentialWarning=""
  Task {do{_ = try await write.value;guard identityEpoch==epoch,session==value else{return};credentialWarning=""}catch{guard identityEpoch==epoch,session==value else{return};credentialWarning=L10n.text("会话保存失败，请重试")}}
 }
 func saveIdentity(){if let session{persistSession(session)}}
 private func refreshSession()async->Bool {
  if let task=refreshTask{return await task.value}
  guard let current=session else{return false}
  let epoch=identityEpoch
  let task=Task { @MainActor in
   defer{if identityEpoch==epoch{refreshTask=nil}}
   do {
    let a=try await perform("POST","auth/refresh",body:["refresh_token":current.refreshToken],as:V2AuthResponse.self)
    guard identityEpoch==epoch,session==current else{return false}
    let next=V2Session(accountID:a.accountID,friendID:a.friendID,accessToken:a.accessToken,refreshToken:a.refreshToken)
    session=next;persistSession(next);return true
   }catch{
    guard identityEpoch==epoch,session==current else{return false}
    if (error as? V2APIError)?.code=="MIGRATION_REQUIRED" {
     migrationNeedsProof=true;migrationRequired=true
     disconnect();message=L10n.text("原登录已过期，请验证原账号后绑定 Google")
    }else if (error as? V2APIError)?.code=="UNAUTHORIZED" {
     logout();message=L10n.text("登录已失效，请重新登录")
    }
    return false
   }
  }
  refreshTask=task;return await task.value
 }
 func connect(){guard !migrationRequired,friendInteractionEnabled,!systemSuspended,let session,let base=baseURL()else{return};disconnect();connecting=true;message=L10n.text("正在连接中控…");var c=URLComponents(url:base.appendingPathComponent("v2/ws"),resolvingAgainstBaseURL:false)!;c.scheme=base.scheme=="https" ? "wss":"ws";let ws=network.webSocketTask(with:c.url!);socket=ws;socketAccessToken=session.accessToken;ws.resume();let gen=generation;Task{do{try await ws.send(.data(try JSONSerialization.data(withJSONObject:["access_token":session.accessToken,"device_id":deviceID,"protocol":2,"supports_credential_refresh":true])));guard gen==generation else{return};send("sync");await receive(ws,generation:gen)}catch{if gen==generation{failed(error)}}}}
 func disconnect(){stopAvatarRuns();generation+=1;socketCredentialRefresh?.cancel();socketCredentialRefresh=nil;socketRenewalRequestID=nil;socketRenewalAccessToken=nil;socketAccessToken=nil;reconnect?.cancel();reconnect=nil;socket?.cancel(with:.goingAway,reason:nil);socket=nil;connected=false;connecting=false;localActive=true;gate.reset();pets.hideAll(except:systemSuspended ? nil:localOwnerID)}
 private func failed(_ error:Error){disconnect();message=L10n.text("连接中断，正在恢复…");guard friendInteractionEnabled else{return};reconnect=Task{try? await Task.sleep(nanoseconds:3_000_000_000);guard !Task.isCancelled else{return};_ = await refreshSession();if !Task.isCancelled{connect()}}}
 func send(_ action:String,fields:[String:Any]=[:]){guard let socket,friendInteractionEnabled,!systemSuspended else{return};let id=UUID().uuidString;var body=fields;body["action"]=action;body["request_id"]=id;guard let data=try? JSONSerialization.data(withJSONObject:body)else{return};gate.sent(id,at:ProcessInfo.processInfo.systemUptime);let gen=generation;Task{do{try await socket.send(.data(data))}catch{if gen==generation{failed(error)}}}}
private func receive(_ ws:URLSessionWebSocketTask,generation gen:Int)async{do{while gen==generation{let raw=try await ws.receive();guard gen==generation else{return};let data:Data;switch raw{case .data(let d):data=d;case .string(let s):data=Data(s.utf8);@unknown default:continue};if let control=try? JSONDecoder().decode(V2SocketCredentialControl.self,from:data),control.type=="auth_refresh_required" {renewSocketCredentials(ws,generation:gen);continue};let state=try JSONDecoder.petLink.decode(V2SnapshotDTO.self,from:data);if state.requestID==socketRenewalRequestID{socketAccessToken=socketRenewalAccessToken;socketRenewalRequestID=nil;socketRenewalAccessToken=nil;socketCredentialRefresh=nil};guard gate.accept(state.requestID,now:ProcessInfo.processInfo.systemUptime,leaseMS:state.leaseMS)else{continue};localCompanion.rememberStyle(state.own.style,accountID:state.selfID);localStyle=localCompanion.style;initialAppearanceReady=true;localActive=false;connected=true;connecting=false;snapshot=state;message=L10n.text("已连接 · {0}", profileInfo?.nickname ?? state.own.nickname);if let error=state.error{operationNotice=visitErrorLabel(error)};let legacy=state.pets.map{Pet(owner:$0.ownerID,name:$0.nickname,location:$0.locationID,target:$0.targetID,phase:$0.phase,revision:$0.revision,style:$0.style,wave:$0.waveSequence)};pets.update(legacy,selfID:state.selfID);for pet in state.pets{if let old=lastWaves[pet.ownerID],old < pet.waveSequence,pet.waveExpiresAt.map({$0>Date()})==true{pets.wave(pet.ownerID,count:min(Int(pet.waveSequence-old),4))};lastWaves[pet.ownerID]=pet.waveSequence};for hide in state.hides{pets.hide(hide.petID);send("ack",fields:["pet_id":hide.petID,"revision":hide.revision])};processAvatarTasks(state.avatarTasks ?? [])}}catch{if gen==generation{failed(error)}}}
 private func renewSocketCredentials(_ ws:URLSessionWebSocketTask,generation gen:Int){
  guard socketCredentialRefresh==nil,let account=session?.accountID else{return}
  socketCredentialRefresh=Task { @MainActor in
   do {
    if session?.accessToken==socketAccessToken,!(await refreshSession()){throw URLError(.userAuthenticationRequired)}
    guard !Task.isCancelled,gen==generation,let current=session,current.accountID==account else{return}
    let id=UUID().uuidString
    socketRenewalRequestID=id;socketRenewalAccessToken=current.accessToken
    let data=try JSONSerialization.data(withJSONObject:["action":"reauth","request_id":id,"access_token":current.accessToken])
    gate.sent(id,at:ProcessInfo.processInfo.systemUptime)
    try await ws.send(.data(data))
    // Keep renewal single-flight until its response confirms authorization.
   }catch{if gen==generation{failed(error)}}
  }
 }
 private func tick(){if !gate.valid(at:ProcessInfo.processInfo.systemUptime),!localActive {stopAvatarRuns();pets.hideAll();localActive=true};if localMode{updateLocalCompanion()};ticks+=1;if ticks%5==0,socket != nil,friendInteractionEnabled{send("sync")}}
 func systemSuspend(){systemSuspended=true;disconnect();message=L10n.text("系统休息中，桌宠暂时隐藏")};func systemResume(){systemSuspended=false;if friendInteractionEnabled{connect()}}
 func setFriendInteractionEnabled(_ enabled:Bool){guard friendInteractionEnabled != enabled else{return};friendInteractionEnabled=enabled;if enabled{connect()}else{disconnect();message=L10n.text("好友互动已关闭")}}
 func contactName(_ id:String)->String{snapshot?.contacts.first(where:{$0.accountID==id}).map{$0.note.isEmpty ? $0.nickname:$0.note} ?? L10n.text("好友")}
 func setAccepting(_ value:Bool){accepting=value;send("pause_accepting",fields:["enabled":!value])}
 func requestVisit(_ contact:V2ContactDTO){operationNotice="";guard contact.accepting else{operationNotice=visitErrorLabel("HOST_PAUSED");return};selectedTab=2;send("visit_request",fields:["peer_id":contact.accountID])};func respondVisit(_ request:V2VisitRequestDTO,accept:Bool){send("visit_respond",fields:["visit_id":request.id,"enabled":accept])}
 func addFriend(){let fid=normalizedCredentialPaste(friendIDInput);guard !fid.isEmpty else{return};Task{do{_ = try await perform("POST","friends/request",body:["friend_id":fid],authenticated:true,as:V2FriendRequestDTO.self);friendIDInput="";operationNotice=L10n.text("好友申请已发送");send("sync")}catch{operationNotice=L10n.text("添加失败：{0}", describe(error))}}}
 func respondFriend(_ request:V2FriendRequestDTO,accept:Bool){Task{do{_ = try await perform("POST","friends/respond",body:["request_id":request.id,"accept":accept],authenticated:true,as:OKResponse.self);send("sync")}catch{operationNotice=L10n.text("处理申请失败：{0}", describe(error))}}}
 func updatePolicy(_ contact:V2ContactDTO,trusted:Bool?=nil,share:Bool?=nil,note:String?=nil){Task{do{_ = try await perform("PATCH","contacts/\(contact.accountID)/policy",body:["trusted":trusted ?? contact.trusted,"share_agent":share ?? contact.shareAgent,"note":note ?? contact.note],authenticated:true,as:OKResponse.self);send("sync")}catch{operationNotice=L10n.text("更新联系人失败：{0}", describe(error))}}}
 func beginNote(_ contact:V2ContactDTO){editingNoteContactID=contact.accountID;noteDraft=contact.note}
 func saveNote(){guard let id=editingNoteContactID,let c=snapshot?.contacts.first(where:{$0.accountID==id})else{return};updatePolicy(c,note:noteDraft);editingNoteContactID=nil;noteDraft=""}
 func remove(_ contact:V2ContactDTO,block:Bool=false){Task{do{_ = try await perform("POST",block ? "friends/block":"friends/remove",body:["account_id":contact.accountID],authenticated:true,as:OKResponse.self);send("sync")}catch{operationNotice=L10n.text("联系人操作失败：{0}", describe(error))}}}
 var avatarAnswerProvider:String {
  guard let account=session?.accountID else{return "claude"}
  let provider=defaults.string(forKey:"avatar-answer-provider:"+account) ?? "claude"
  return AvatarAnswerRuntime.providers.contains(provider) ? provider:"claude"
 }
 func resolvedAvatarProvider(_ provider:String)->String{provider=="owner_default" ? avatarAnswerProvider:provider}
 func selectAvatarProvider(_ provider:String){
  guard avatarAuthorization.isReady,let account=session?.accountID,AvatarAnswerRuntime.providers.contains(provider),avatarProviderReports[provider]?.supported==true else{return}
  objectWillChange.send();defaults.set(provider,forKey:"avatar-answer-provider:"+account)
 }
 func refreshAvatarProviders(){
  let epoch=identityEpoch
  guard avatarProviderRefresh.begin(epoch:epoch,authorized:avatarAuthorization.isReady) else{return}
  avatarProviderChecking=true
  Task { @MainActor in
   let reports=await Task.detached{Dictionary(uniqueKeysWithValues:AvatarAnswerRuntime.providers.map{($0,AvatarAnswerRuntime.availability($0))})}.value
   let accepted=avatarProviderRefresh.finish(epoch:epoch,currentEpoch:identityEpoch)
   avatarProviderChecking=avatarProviderRefresh.isChecking
   if accepted{avatarProviderReports=reports}
  }
 }
 func updateAvatarPolicy(_ contact:V2ContactDTO,enabled:Bool){Task{do{let current=contact.avatarProvider;let body:[String:Any]=["allow_auto_ask":enabled,"provider":current];_ = try await perform("PATCH","contacts/\(contact.accountID)/avatar-policy",body:body,authenticated:true,version:3,as:AvatarPolicyResponse.self);operationNotice=enabled ? L10n.text("已允许 {0} 通过来访桌宠自动提问", contact.nickname):L10n.text("已关闭 {0} 的自动提问", contact.nickname);send("sync")}catch{operationNotice=L10n.text("数字分身权限更新失败：{0}", describe(error))}}}

 var avatarContacts:[V2ContactDTO]{(snapshot?.contacts ?? []).filter{$0.avatarKeyReady}}
 func isVisiting(_ contact:V2ContactDTO)->Bool{snapshot?.pets.contains{$0.ownerID==contact.accountID && $0.phase=="visit" && $0.locationID==snapshot?.selfID} ?? false}
 func avatarChatAvailability(_ contact:V2ContactDTO)->AvatarChatAvailability{AvatarChatAvailability.resolve(connected:connected,online:contact.online,keyReady:contact.avatarKeyReady,visiting:isVisiting(contact))}
 func canAskAvatar(_ contact:V2ContactDTO)->Bool {
  avatarAuthorization.isReady && avatarChatAvailability(contact) == .available
 }
 func avatarAvailability(_ contact:V2ContactDTO)->String {
  if !connected{return L10n.text("正在连接")}
  if !contact.online{return L10n.text("离线")}
  return canAskAvatar(contact) ? L10n.text("可以提问"):L10n.text("等待桌宠来访")
 }
 func openAvatarChat(_ contact:V2ContactDTO){
  guard avatarChatAvailability(contact) == .available else{return}
  if !avatarAuthorization.isReady{pendingAvatarOwner=contact.accountID;pendingAvatarApproval=nil;avatarAuthorizationPresented=true;return}
  selectedAvatarOwner=contact.accountID;selectedTab=1
 }
 func closeAvatarChat(){selectedAvatarOwner="";selectedTab=1}
 func presentAvatarAuthorization(){pendingAvatarOwner=nil;pendingAvatarApproval=nil;avatarAuthorizationPresented=true}
 func cancelAvatarAuthorization(){avatarAuthorizationPresented=false;pendingAvatarOwner=nil;pendingAvatarApproval=nil;pendingAvatarRemember=false}
 func authorizeAvatar(){
  let epoch=identityEpoch
  Task{
   await avatarAuthorization.prepare(explicit:true)
   guard epoch==identityEpoch,avatarAuthorization.isReady else{return}
   let owner=pendingAvatarOwner,approval=pendingAvatarApproval,remember=pendingAvatarRemember
   cancelAvatarAuthorization()
   if let owner,let contact=snapshot?.contacts.first(where:{$0.accountID==owner}),canAskAvatar(contact){openAvatarChat(contact)}
   else if owner != nil{operationNotice=L10n.text("好友当前无法聊天，可以稍后从联系人中重新打开。")}
   if let approval,let current=snapshot?.avatarTasks?.first(where:{$0.id==approval.id && $0.task.state=="pending_approval"}){respondAvatar(current,accept:true,remember:remember)}
  }
 }
 private func nextAvatarSequence()->Int64 {let key="avatar-sequence";let next=defaults.object(forKey:key)==nil ? Int64(1):defaults.object(forKey:key) as? Int64 ?? Int64(defaults.integer(forKey:key)+1);defaults.set(next+1,forKey:key);return next}
 private func avatarObject(_ envelope:AvatarEnvelopeDTO)throws->[String:Any] {let data=try JSONEncoder.avatar.encode(envelope);guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]else{throw AvatarCryptoError.invalidEnvelope};return object}

 func askAvatar() {
  guard !avatarSubmitting else{return}
  guard avatarAuthorization.isReady else{presentAvatarAuthorization();return}
  let question=avatarQuestion.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !question.isEmpty,question.utf8.count<=8192,let account=session?.accountID else{message=L10n.text("请输入不超过 8192 字节的问题");return}
  let owner=selectedAvatarOwner
  guard !avatarChat.isWaiting(owner:owner) else{return}
  guard let contact=avatarContacts.first(where:{$0.accountID==owner}),canAskAvatar(contact) else{message=L10n.text("请选择已经来访且在线的好友 Agent");return}
  let epoch=identityEpoch
  let taskID="dlg_"+UUID().uuidString.lowercased()
  avatarSubmitting=true;avatarChat.begin(taskID,owner:owner,question:question,visitRevision:snapshot?.pets.first(where:{$0.ownerID==owner})?.revision)
  Task {
   defer{if identityEpoch==epoch{avatarSubmitting=false}}
   do {
    guard let identity=avatarAuthorization.identity else{throw AvatarAgentError.unsupported(L10n.text("本机加密身份不可用"))}
    let cap=try await perform("GET","avatar/contacts/\(owner)/capability",authenticated:true,version:3,as:AvatarContactCapabilityDTO.self)
    guard identityEpoch==epoch,session?.accountID==account else{return}
    let now=Date()
    let metadata=AvatarEnvelopeMetadata(taskID:taskID,senderAccountID:account,senderDeviceID:deviceID,recipientAccountID:owner,recipientDeviceID:cap.deviceID,visitRevision:cap.visitRevision,policyRevision:cap.policyRevision,sequence:nextAvatarSequence(),createdAt:now,expiresAt:now.addingTimeInterval(120))
    let envelope=try AvatarCrypto.seal(AvatarQuestionPayload(question:question),metadata:metadata,sender:identity,recipientAgreementPublicKey:cap.agreementPublicKey)
    let task=try await perform("POST","avatar/tasks",body:["owner_id":owner,"envelope":try avatarObject(envelope)],authenticated:true,version:3,as:AvatarTaskDTO.self)
    guard identityEpoch==epoch,session?.accountID==account else{return}
    avatarChat.clearSentDraft(owner:owner,matching:question)
    _ = avatarChat.update([AvatarRelayDTO(task:task,request:nil,result:nil,peerKey:nil)],account:account,device:deviceID)
    send("sync")
   } catch {if identityEpoch==epoch{avatarChat.submissionFailed(taskID,message:L10n.text("提问失败：{0}", describe(error)))}}
  }
 }

 func respondAvatar(_ relay:AvatarRelayDTO,accept:Bool,remember:Bool=false){
  guard connected,!avatarResponding.contains(relay.id),!remember || accept else{return}
  guard !accept || avatarAuthorization.isReady else{pendingAvatarApproval=relay;pendingAvatarOwner=nil;pendingAvatarRemember=remember;avatarAuthorizationPresented=true;return}
  let epoch=identityEpoch
  avatarResponding.insert(relay.id)
  Task{
   defer{if identityEpoch==epoch{avatarResponding.remove(relay.id)}}
   do{
    let response=try await perform("POST","avatar/tasks/\(relay.task.id)/respond",body:["accept":accept,"remember":remember],authenticated:true,version:3,as:AvatarApprovalResponse.self)
    guard identityEpoch==epoch else{return}
    if remember{avatarOwnerNotice.set(relay.id,message:response.autoAskGranted==true ? L10n.text("已始终允许这位好友提问，可在联系人详情中关闭。"):L10n.text("本次已允许，服务端未确认永久授权，请稍后重试。"))}
    send("sync")
   }catch{if identityEpoch==epoch{avatarOwnerNotice.set(relay.id,message:L10n.text("处理数字分身请求失败：{0}", describe(error)))}}
  }
 }
 func cancelAvatar(_ relay:AvatarRelayDTO){Task{do{_ = try await perform("POST","avatar/tasks/\(relay.task.id)/cancel",body:[:],authenticated:true,version:3,as:OKResponse.self);send("sync")}catch{avatarChat.notice(relay.id,message:L10n.text("取消失败：{0}", describe(error)))}}}

 private func processAvatarTasks(_ relays:[AvatarRelayDTO]) {
  defer{refreshVisitorChats()}
  guard let account=session?.accountID else{return}
  for (id,run) in avatarRuns{if !relays.contains(where:{$0.id==id && $0.task.ownerID==account && ["routed","running"].contains($0.task.state)}){run.cancel();avatarRuns.removeValue(forKey:id)}}
  avatarOwnerNotice.update(relays,account:account,device:deviceID)
  let current=avatarChat.update(relays,account:account,device:deviceID)
  guard let identity=avatarAuthorization.identity else{return}
  for relay in current where relay.task.state=="completed" && !handledAvatarTasks.contains("result:"+relay.id) {
   do {
    guard let envelope=relay.result,let key=relay.peerKey else{continue}
    guard envelope.verify(signingPublicKey:key.signingPublicKey),
      envelope.taskID==relay.id,envelope.recipientAccountID==account,
      envelope.recipientDeviceID==deviceID else{throw AvatarCryptoError.invalidEnvelope}
    let result=try AvatarCrypto.open(envelope,recipient:identity,as:AvatarAnswerPayload.self)
    avatarChat.complete(relay.id,answer:result.answer,provider:result.provider,errorCode:result.errorCode)
    handledAvatarTasks.insert("result:"+relay.id)
   } catch {avatarChat.fail(relay.id,message:L10n.text("回答校验失败，内容已丢弃"))}
  }
  for relay in relays {
   if relay.task.ownerID==account,relay.task.state=="routed",relay.request != nil,!handledAvatarTasks.contains("run:"+relay.id) {
    handledAvatarTasks.insert("run:"+relay.id);runAvatarTask(relay,identity:identity)
   }
  }
 }
 private func refreshVisitorChats(){
  guard connected,avatarAuthorization.isReady,let snapshot else{pets.setVisitorChats([]);return}
  pets.setVisitorChats(snapshot.contacts.compactMap{contact in
   guard canAskAvatar(contact),let pet=snapshot.pets.first(where:{$0.ownerID==contact.accountID}) else{return nil}
   return avatarChat.visitorBubble(owner:contact.accountID,name:contactName(contact.accountID),visitRevision:pet.revision)
  })
 }
 private func runAvatarTask(_ relay:AvatarRelayDTO,identity:AvatarDeviceIdentity) {
  let epoch=identityEpoch
  func checkRun()throws{try Task.checkCancellation();guard identityEpoch==epoch,session?.accountID==relay.task.ownerID,avatarAuthorization.isReady else{throw CancellationError()}}
  let run=Task { @MainActor in
   defer{if identityEpoch==epoch{avatarRuns.removeValue(forKey:relay.id)}}
   do {
    try checkRun()
    guard let envelope=relay.request,let peer=relay.peerKey,envelope.verify(signingPublicKey:peer.signingPublicKey) else{throw AvatarCryptoError.invalidEnvelope}
    let input=try AvatarCrypto.open(envelope,recipient:identity,as:AvatarQuestionPayload.self)
    _ = try await perform("POST","avatar/tasks/\(relay.id)/start",body:[:],authenticated:true,version:3,as:OKResponse.self)
    try checkRun()
    let provider=resolvedAvatarProvider(relay.task.provider)
    let payload:AvatarAnswerPayload
    do {
     let answer=try await AvatarAnswerRuntime.answerAsync(provider:provider,question:input.question,timeout:45)
     try checkRun()
     payload=AvatarAnswerPayload(answer:answer,provider:provider,completedAt:Date())
    } catch {
     try checkRun()
     // Only a fixed code and public message cross the encrypted boundary.
     // Never forward raw stderr, executable paths, configuration or credentials.
     payload=AvatarAnswerPayload(answer:L10n.text("对方本地 Agent 回答失败，请稍后重新提问"),provider:provider,completedAt:Date(),errorCode:"AGENT_EXECUTION_FAILED")
    }
    try checkRun()
    let now=Date()
    let metadata=AvatarEnvelopeMetadata(taskID:relay.id,senderAccountID:relay.task.ownerID,senderDeviceID:deviceID,recipientAccountID:relay.task.requesterID,recipientDeviceID:relay.task.requesterDeviceID,visitRevision:relay.task.visitRevision,policyRevision:relay.task.policyRevision,sequence:nextAvatarSequence(),createdAt:now,expiresAt:now.addingTimeInterval(120))
    let result=try AvatarCrypto.seal(payload,metadata:metadata,sender:identity,recipientAgreementPublicKey:peer.agreementPublicKey)
    _ = try await perform("POST","avatar/tasks/\(relay.id)/complete",body:["envelope":try avatarObject(result)],authenticated:true,version:3,as:OKResponse.self)
    avatarOwnerNotice.set(relay.id,message:payload.errorCode==nil ? L10n.text("数字分身已回答，服务端仅转发密文"):L10n.text("本地 Agent 回答失败，已加密通知提问方"))
    send("sync")
   } catch {if identityEpoch==epoch,!Task.isCancelled{avatarOwnerNotice.set(relay.id,message:L10n.text("数字分身处理或回传失败：{0}", describe(error)))}}
  }
  avatarRuns[relay.id]=run
 }
 func publishAgent(_ event:NormalizedAgentEvent){let iso=ISO8601DateFormatter();send("agent_status",fields:["agent":["provider":event.provider,"session_ref":event.sessionRef,"state":event.state.rawValue,"sequence":event.sequence,"expires_at":iso.string(from:event.expiresAt)]])}
}
struct OKResponse:Codable{let ok:Bool}
struct AvatarApprovalResponse:Codable{let ok:Bool;let autoAskGranted:Bool?;enum CodingKeys:String,CodingKey{case ok;case autoAskGranted="auto_ask_granted"}}
struct AvatarPolicyResponse:Codable{let allowAutoAsk:Bool;let provider:String;let policyRevision:Int64;enum CodingKeys:String,CodingKey{case provider;case allowAutoAsk="allow_auto_ask",policyRevision="policy_revision"}}
