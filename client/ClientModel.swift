import AppKit
import SwiftUI

@MainActor final class ClientModel: ObservableObject {
 @Published var endpoint:String
 @Published var pairCode=""
 @Published var paired:Bool
 @Published var connected=false
 @Published var connecting=false
 @Published var pairing=false
 @Published var message=L10n.text("尚未连接")
 @Published var snapshot:Snapshot?
 @Published var paused=false
 @Published var credentialWarning=""
 let profile:String
 private let defaults:UserDefaults
 private var token:String?
 private var socket:URLSessionWebSocketTask?
 private let session=URLSession(configuration:.ephemeral)
 private var timer:Timer?
 private var reconnect:Task<Void,Never>?
 private var gate=LeaseGate()
 private var generation=0
 private var ticks=0
 private var systemSuspended=false
 private var observers:[NSObjectProtocol]=[]
 let pets=PetWindows()
 private var lastWaves:[String:Int64]=[:]
 init(profile:String, endpointOverride:String?=nil, tokenOverride:String?=nil) {
  self.profile=profile;defaults=UserDefaults(suiteName:"com.fantasyce.petlink."+profile)!
  endpoint=PetLinkEndpoint.resolve(saved:defaults.string(forKey:"endpoint"),override:endpointOverride,profile:profile)
  token=tokenOverride ?? Vault.read(profile);paired=token != nil
  if Vault.usesPrivateFile(profile){credentialWarning=L10n.text("身份保存在本机私有文件（仅当前用户可读），未使用钥匙串。")}
  timer=Timer(timeInterval:0.2,repeats:true){[weak self] _ in Task{@MainActor in self?.tick()}}
  RunLoop.main.add(timer!,forMode:.common)
  let nc=NSWorkspace.shared.notificationCenter
  observers.append(nc.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.systemSuspend()}})
  observers.append(nc.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.systemResume()}})
  observers.append(nc.addObserver(forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.systemSuspend()}})
  observers.append(nc.addObserver(forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.systemResume()}})
  if paired {connect()}
 }
 private func baseURL()->URL? {
  guard let u=URL(string:endpoint.trimmingCharacters(in:.whitespacesAndNewlines)),u.user==nil,u.password==nil,u.query==nil,u.fragment==nil else{return nil}
  guard u.scheme=="https" || (u.scheme=="http" && ["127.0.0.1","localhost"].contains(u.host ?? "")) else{return nil};return u
 }
 func pair() {
  guard !pairing,let base=baseURL(),!pairCode.isEmpty else{message=L10n.text("请输入有效的 HTTPS 地址和配对码");return}
  pairing=true;message=L10n.text("正在配对…")
  var req=URLRequest(url:base.appendingPathComponent("pair"));req.httpMethod="POST";req.timeoutInterval=15
  req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.httpBody=try? JSONSerialization.data(withJSONObject:["code":pairCode])
  Task {defer{pairing=false};do {
   let(data,response)=try await session.data(for:req)
   guard (response as? HTTPURLResponse)?.statusCode==200 else{throw NSError(domain:"Pair",code:1,userInfo:[NSLocalizedDescriptionKey:String(data:data,encoding:.utf8) ?? L10n.text("配对失败")])}
   guard let obj=try JSONSerialization.jsonObject(with:data) as? [String:String],let value=obj["token"] else{throw URLError(.cannotParseResponse)}
   token=value;paired=true;pairCode="";defaults.set(endpoint,forKey:"endpoint")
   saveIdentity();connect()
  }catch{message=L10n.text("配对失败：{0}", error.localizedDescription)}}
 }
 func saveIdentity(){guard let token=token else{return};do {
  credentialWarning=try Vault.write(token,profile:profile) ? "":L10n.text("身份保存在本机私有文件（仅当前用户可读），未使用钥匙串。")
 }catch{credentialWarning=L10n.text("身份尚未保存：{0}。请重试保存后再退出。", error.localizedDescription)}}
 func connect() {
  guard !paused,!systemSuspended,let token=token,let base=baseURL() else{return}
  disconnect();connecting=true;message=L10n.text("正在连接中控…")
  var components=URLComponents(url:base.appendingPathComponent("ws"),resolvingAgainstBaseURL:false)!
  components.scheme = base.scheme=="https" ? "wss":"ws"
  let ws=session.webSocketTask(with:components.url!);socket=ws;ws.resume();let gen=generation
  Task {do {
   let data=try JSONSerialization.data(withJSONObject:["token":token]);try await ws.send(.data(data))
   guard gen==generation else{return};send("sync");await receive(ws,generation:gen)
  }catch{if gen==generation{failed(error)}}}
 }
 func disconnect(){generation+=1;reconnect?.cancel();reconnect=nil;socket?.cancel(with:.goingAway,reason:nil);socket=nil;connected=false;connecting=false;gate.reset();pets.hideAll()}
 func suspend(){paused=true;disconnect();message=L10n.text("已暂停，桌宠暂时隐藏")}
 func resume(){paused=false;connect()}
 func systemSuspend(){systemSuspended=true;disconnect();message=paused ? L10n.text("已暂停，桌宠暂时隐藏"):L10n.text("系统休息中，桌宠暂时隐藏")}
 func systemResume(){systemSuspended=false;if !paused{connect()}}
 func togglePause(){if paused{resume()}else{suspend()}}
 func send(_ action:String,fields:[String:Any]=[:]) {
  guard let ws=socket,!paused,!systemSuspended else{return}
  let id=UUID().uuidString;var body=fields;body["action"]=action;body["id"]=id
  guard let data=try? JSONSerialization.data(withJSONObject:body) else{return}
  gate.sent(id,at:ProcessInfo.processInfo.systemUptime);let gen=generation
  Task {do{try await ws.send(.data(data))}catch{if gen==generation{failed(error)}}}
 }
 private func receive(_ ws:URLSessionWebSocketTask,generation gen:Int) async {
  do {while gen==generation {
   let raw=try await ws.receive();guard gen==generation else{return}
   let data:Data;switch raw{case .data(let d):data=d;case .string(let s):data=Data(s.utf8);@unknown default:continue}
   let state=try JSONDecoder().decode(Snapshot.self,from:data)
   guard gate.accept(state.id,now:ProcessInfo.processInfo.systemUptime,leaseMS:state.leaseMS) else{continue}
   connected=true;connecting=false;snapshot=state
   if !state.error.isEmpty {message=state.error}else{message=L10n.text("已连接 · ")+state.name}
   pets.update(state.pets,selfID:state.selfID)
   for pet in state.pets {if let last=lastWaves[pet.owner],last != pet.wave{pets.wave(pet.owner)};lastWaves[pet.owner]=pet.wave}
   for hide in state.hides {pets.hide(hide.pet);send("ack",fields:["pet":hide.pet,"revision":hide.revision])}
  }}catch{if gen==generation{failed(error)}}
 }
 private func failed(_ error:Error){disconnect();message=L10n.text("连接中断，正在重连…");guard !paused else{return};reconnect=Task{try? await Task.sleep(nanoseconds:3_000_000_000);if !Task.isCancelled{connect()}}}
 private func tick(){
  if !gate.valid(at:ProcessInfo.processInfo.systemUptime){pets.hideAll()}
  ticks+=1;if ticks%5==0,socket != nil,!paused{send("sync")}
 }
 var locationText:String {
  guard let p=snapshot?.own else{return L10n.text("等待中控确认位置")}
  if p.phase=="travel"{return p.target==p.owner ? L10n.text("正在回家…"):L10n.text("正在出发…")}
  if p.location==p.owner{return L10n.text("我的桌宠在家")}
  let name=snapshot?.friends.first{$0.id==p.location}?.name ?? p.location
  return L10n.text("正在 {0} 家做客", name)
 }
}
