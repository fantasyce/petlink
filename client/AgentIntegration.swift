import AppKit
import Darwin
import Foundation
import SwiftUI

struct AgentProviderViewState:Identifiable,Equatable {
 let id:String
 var title:String
 var version:String
 var support:String
 var state:PetLinkAgentState
 var sessionRef:String
}

@MainActor final class AgentCoordinator:ObservableObject {
 @Published var providers:[AgentProviderViewState] = [
  .init(id:"codex",title:"Codex",version:L10n.text("检测中"),support:"",state:.disconnected,sessionRef:""),
  .init(id:"claude",title:"Claude Code",version:L10n.text("检测中"),support:"",state:.disconnected,sessionRef:""),
  .init(id:"deepseek",title:"DeepSeek Harness",version:L10n.text("检测中"),support:"",state:.disconnected,sessionRef:"")]
 @Published var message=L10n.text("本地桥接正在启动")
 @Published private(set) var connectionNotice=""
 @Published private(set) var sessions:[NormalizedAgentEvent]=[]
 private var registry=AgentSessionRegistry()
 private var trackingEpoch=0
 var trackingEnabled=true {didSet{trackingEpoch+=1;if !trackingEnabled {registry=AgentSessionRegistry();latestSequence.removeAll();cachedEvents.removeAll();observedSessions=["claude":[],"deepseek":[]];claudeConnected=false;dshConnected=false;claudeTitles.removeAll();dshTitles.removeAll();refreshLocalSessions()}else{probeCodex()}}}
 var localStatusChanged:(([NormalizedAgentEvent])->Void)?
 private func refreshLocalSessions(){sessions=registry.ordered();localStatusChanged?(sessions)}
 @Published private(set) var claudeConnected=false
 private(set) var claudeTitles:[String:String]=[:]
 @Published private(set) var dshConnected=false
 private(set) var dshTitles:[String:String]=[:]
 @Published private(set) var codexConnected=false
 @Published private(set) var codexIssue=""
 @Published private(set) var versionIssues:[String:String]=[:]
 @Published private(set) var connectionsChecking=false
 var versionsChanged:(()->Void)?
 private let versionMonitor=AgentVersionMonitor()
 private let versionQueue=DispatchQueue(label:"com.fantasyce.petlink.agent-versions",qos:.utility)
 private var versionDetectionRunning=false
 private var lastVersionCheck=Date.distantPast
	@Published var codexThreads:[String]=[]
	@Published var selectedCodexThread=""
	@Published var observedSessions:[String:[String]]=["claude":[],"deepseek":[]]
	@Published var selectedSessions:[String:String]=[:]
 let socketPath:String
 private var listener:Int32 = -1
 private var source:DispatchSourceRead?
 private var latestSequence:[String:Int64]=[:]
	private var cachedEvents:[String:NormalizedAgentEvent]=[:]
	private var activeProvider=""
	private var activeRef=""
	private var codexSequence:Int64=0
	private var codexTimer:Timer?
	private var codexProbeRunning=false
 private let publish:(NormalizedAgentEvent)->Void

 init(profile:String,publish:@escaping(NormalizedAgentEvent)->Void){
  self.publish=publish
  let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PetLink",isDirectory:true)
  try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  socketPath=root.appendingPathComponent(profile=="default" ? "agent-status.sock":"agent-status-\(profile).sock").path
  start();detect()
  if profile=="default" {
   do {if try ClaudeHookSettings.removeLegacyHooks(at:ClaudeSessionDiscovery.configurationHome.appendingPathComponent("settings.json")){message=L10n.text("Agent 自动连接已就绪")}}
   catch {message=L10n.text("旧版 Claude 连接配置未能清理，请重启 PetLink 后重试。");connectionNotice=message}
  }
  codexTimer=Timer.scheduledTimer(withTimeInterval:3,repeats:true){[weak self] _ in Task{@MainActor in
   guard let self else{return};self.probeCodex();if Date().timeIntervalSince(self.lastVersionCheck)>=60{self.detect()}
  }};probeCodex()
 }
 deinit {codexTimer?.invalidate();source?.cancel();if listener >= 0{Darwin.close(listener)};Darwin.unlink(socketPath)}

 private func start(){
  guard socketPath.utf8.count < MemoryLayout<sockaddr_un>.size-2 else{message=L10n.text("本地桥接路径过长");connectionNotice=message;return}
  Darwin.unlink(socketPath)
  let fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0);guard fd >= 0 else{message=L10n.text("无法建立本地桥接");connectionNotice=message;return}
  var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
  let pathCapacity=MemoryLayout.size(ofValue:address.sun_path)
  socketPath.withCString{path in withUnsafeMutablePointer(to:&address.sun_path){raw in raw.withMemoryRebound(to:CChar.self,capacity:pathCapacity){dest in _ = strlcpy(dest,path,pathCapacity)}}}
  let bound=withUnsafePointer(to:&address){ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
  guard bound==0,Darwin.listen(fd,8)==0 else{Darwin.close(fd);message=L10n.text("本地桥接端口被占用");connectionNotice=message;return}
  _ = Darwin.chmod(socketPath,0o600);listener=fd
  let q=DispatchQueue(label:"com.fantasyce.petlink.agent-socket")
  let src=DispatchSource.makeReadSource(fileDescriptor:fd,queue:q);source=src
  src.setEventHandler{[weak self] in Self.acceptOne(fd){event in Task{@MainActor [weak self] in self?.receive(event)}}};src.resume();message=L10n.text("本地桥接已就绪")
 }
 nonisolated private static func acceptOne(_ listener:Int32,deliver:@escaping(NormalizedAgentEvent)->Void){
  let fd=Darwin.accept(listener,nil,nil);guard fd >= 0 else{return};defer{Darwin.close(fd)}
  var uid:uid_t=0,gid:gid_t=0;guard getpeereid(fd,&uid,&gid)==0,uid==getuid() else{return}
  var bytes=[UInt8](repeating:0,count:4097);let count=Darwin.read(fd,&bytes,4097);guard count>0,count<=4096 else{return}
  let data=Data(bytes.prefix(count));guard let event=try? AgentEventNormalizer.decode(data),event.sequence>=0,event.provider != "claude",event.provider != "deepseek" else{return}
  deliver(AgentEventNormalizer.normalize(event))
 }
 private func receive(_ event:NormalizedAgentEvent){
  guard trackingEnabled else{return}
  registry.receive(event);refreshLocalSessions()
	let key=event.provider+":"+event.sessionRef;let old=latestSequence[key] ?? -1;guard event.sequence>old else{return};latestSequence[key]=event.sequence;cachedEvents[key]=event
	if event.provider != "codex" {var sessions=observedSessions[event.provider] ?? [];if !sessions.contains(event.sessionRef){sessions.append(event.sessionRef);observedSessions[event.provider]=sessions}}
  let retained=Set(registry.events.keys)
  latestSequence=latestSequence.filter{retained.contains($0.key)}
  cachedEvents=cachedEvents.filter{retained.contains($0.key)}
  for provider in observedSessions.keys {observedSessions[provider]=observedSessions[provider]?.filter{retained.contains(provider+":"+$0)}}
	guard activeProvider==event.provider,activeRef==event.sessionRef else{return}
  if let i=providers.firstIndex(where:{$0.id==event.provider}){providers[i].state=event.state;providers[i].sessionRef=event.sessionRef}
  publish(event)
 }
	func selectSession(provider:String,ref:String){
		activeProvider=ref.isEmpty ? "":provider;activeRef=provider=="codex" ? AgentEventNormalizer.sessionRef(provider:provider,sessionID:ref):ref
		selectedCodexThread=provider=="codex" ? ref:""
		selectedSessions=provider=="codex" || ref.isEmpty ? [:]:[provider:ref]
		for i in providers.indices{providers[i].state = .disconnected;providers[i].sessionRef=""}
		guard !ref.isEmpty,let event=cachedEvents[provider+":"+ref] else{return}
		if let i=providers.firstIndex(where:{$0.id==provider}){providers[i].state=event.state;providers[i].sessionRef=event.sessionRef};publish(event)
	}
 private func detect(force:Bool=false){
  guard !versionDetectionRunning else{return};versionDetectionRunning=true;lastVersionCheck=Date()
  versionQueue.async{[weak self] in
   guard let self else{return};let versions=self.versionMonitor.scan(force:force)
   Task{@MainActor [weak self] in
    guard let self else{return};self.versionDetectionRunning=false;var changed=false
    for i in self.providers.indices {
     let id=self.providers[i].id;guard let result=versions[id] else{continue}
     changed = changed || self.providers[i].version != result.version
     self.providers[i].version=result.version;self.versionIssues[id]=result.issue
    }
    if changed{self.versionsChanged?();self.probeCodex()}
    self.finishConnectionCheck()
   }
  }
 }
	private func probeCodex(){
  guard trackingEnabled else{return}
        refreshLocalSessions()
		guard !codexProbeRunning else{return}
		guard let socket=CodexSocketDiscovery.find(home:FileManager.default.homeDirectoryForCurrentUser) else{codexConnected=false;codexIssue="";finishConnectionCheck();return}
		codexProbeRunning=true
		let selected=selectedCodexThread,epoch=trackingEpoch
		DispatchQueue.global(qos:.utility).async{[weak self] in
			let result=try? CodexDaemonProbe.run(socketPath:socket,selected:selected.isEmpty ? nil:selected,observeAll:true)
			Task{@MainActor in
				guard let self else{return}
				self.codexProbeRunning=false
    defer{self.finishConnectionCheck()}
    guard epoch==self.trackingEpoch,self.trackingEnabled else{if self.trackingEnabled{self.probeCodex()};return}
				guard let result else{
     self.codexConnected=false
     self.codexIssue=L10n.text("Codex 状态接口暂不可用，请重试。")
					if let i=self.providers.firstIndex(where:{$0.id=="codex"}){self.providers[i].support=L10n.text("App Server 能力探测失败，不猜测状态")}
					return
				}
				self.codexThreads=result.threads
    self.codexConnected=true
    self.codexIssue=""
				if let i=self.providers.firstIndex(where:{$0.id=="codex"}){self.providers[i].support=L10n.text("App Server 只读连接已验证")}
				if !self.selectedCodexThread.isEmpty && !result.threads.contains(self.selectedCodexThread){self.selectSession(provider:"codex",ref:"")}
				for (thread,event) in result.states {
				 self.codexSequence+=1
				 self.receive(AgentEventNormalizer.normalize(AgentWireEvent(provider:"codex",sessionID:thread,event:event,sequence:self.codexSequence,timestamp:Date())))
				}
			}
		}
	}
 private func finishConnectionCheck(){if !versionDetectionRunning && !codexProbeRunning{connectionsChecking=false}}
 func refreshConnections(){connectionsChecking=true;detect(force:true);probeCodex()}
 func updateClaudeSessions(_ found:[CodexDiscoveredSession],connected:Bool){claudeConnected=trackingEnabled && connected;updateMetadataSessions(found,provider:"claude")}
 func updateDSHSessions(_ found:[CodexDiscoveredSession],connected:Bool){dshConnected=trackingEnabled && connected;updateMetadataSessions(found,provider:"deepseek")}
 private func updateMetadataSessions(_ found:[CodexDiscoveredSession],provider:String){
  guard trackingEnabled else{return}
  var refs=Set<String>(),activeRefs:[String]=[],titles:[String:String]=[:]
  for item in found {
   guard let id=AgentEventNormalizer.metadataSessionID(provider:provider,path:item.path) else{continue}
   let ref=AgentEventNormalizer.sessionRef(provider:provider,sessionID:id)
   refs.insert(ref);titles[ref]=item.title
   if ["working","waiting_approval"].contains(item.snapshot.state){activeRefs.append(ref)}
   let sequence=(latestSequence[provider+":"+ref] ?? 0)+1
   let event=item.snapshot.state=="ended" ? "idle":item.snapshot.state=="cancelled" ? "disconnected":item.snapshot.state
   receive(AgentEventNormalizer.normalize(AgentWireEvent(provider:provider,sessionID:id,event:event,sequence:sequence,timestamp:Date())))
  }
  if activeProvider==provider,!refs.contains(activeRef) {
   if let old=cachedEvents[provider+":"+activeRef] {publish(NormalizedAgentEvent(provider:provider,sessionRef:activeRef,state:.disconnected,sequence:old.sequence+1,occurredAt:Date(),expiresAt:Date().addingTimeInterval(30)))}
   selectSession(provider:provider,ref:"")
  }
  registry.remove(provider:provider,keeping:refs)
  latestSequence=latestSequence.filter{!$0.key.hasPrefix(provider+":") || refs.contains(String($0.key.dropFirst(provider.count+1)))}
  cachedEvents=cachedEvents.filter{$0.value.provider != provider || refs.contains($0.value.sessionRef)}
  observedSessions[provider]=activeRefs
  if provider=="claude"{claudeTitles=titles}else{dshTitles=titles}
  refreshLocalSessions()
 }
}

struct AgentStatusPanel:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject private var coordinator:AgentCoordinator
 @ObservedObject private var conversation:CodexConversationMonitor
 init(model:V2ClientModel){coordinator=model.agentCoordinator;conversation=model.pets.conversation}
 private var items:[LocalSessionItem] {LocalSessionPresentation.visible(watched:watchedSessionItems(conversation.activeSessions),events:coordinator.sessions,tracking:conversation.automaticEnabled)}
 var body:some View {VStack(alignment:.leading,spacing:20){
  HStack {
   Text(L10n.text("本地会话")).font(PencilFont.text(22))
   Spacer()
   Toggle(L10n.text("追踪对话"),isOn:$conversation.automaticEnabled).font(PencilFont.text(12)).fixedSize(horizontal:true,vertical:false).accessibilityIdentifier("session-tracking")
  }
  if items.isEmpty {
   VStack(spacing:10){
    Image(systemName:conversation.automaticEnabled ? "moon.zzz":"pause.circle").font(.system(size:26)).foregroundStyle(PetAppearance.line)
    Text(conversation.automaticEnabled ? L10n.text("暂无进行中的会话"):L10n.text("对话追踪已关闭")).font(PencilFont.text(17))
    Text(conversation.automaticEnabled ? L10n.text("在 Codex、Claude 或 DeepSeek Harness 开始任务后，会自动出现在这里。"):L10n.text("桌宠会继续陪着你，随时可以重新开启追踪。"))
     .font(PencilFont.text(13)).foregroundStyle(PetAppearance.secondary).multilineTextAlignment(.center)
   }.frame(maxWidth:.infinity).padding(.vertical,52).accessibilityIdentifier("local-sessions-empty")
  }else{
   Text(L10n.text("{0} 个进行中", items.count)).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
   ForEach(items){item in
    VStack(alignment:.leading,spacing:12){
     Text(item.title).font(PencilFont.text(17)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
     HStack(spacing:8){
      Text(item.sourcePath.map(LocalConversationProvider.label) ?? agentProviderLabel(item.provider)).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
      Circle().fill(item.state == .waiting_approval ? Color.orange:PetAppearance.accent).frame(width:5,height:5).accessibilityHidden(true)
      Text(item.state == .waiting_approval ? L10n.text("等待回应"):L10n.text("进行中")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
      Spacer(minLength:6)
      if let path=item.sourcePath {
       Button(LocalConversationProvider.openActionLabel(path)){conversation.openInCodex(path)}
        .font(PencilFont.text(12)).accessibilityLabel((LocalConversationProvider.openActionLabel(path)+"：")+item.title)
      }else if item.provider=="codex",let thread=LocalSessionPresentation.codexThread(ref:item.ref,threads:coordinator.codexThreads) {
       Button(L10n.text("打开会话")){conversation.openCodexThread(thread)}.font(PencilFont.text(12)).accessibilityLabel(L10n.text("在 Codex 中打开：")+item.title)
      }
     }
    }.padding(14).background(PetAppearance.surface,in:PencilOutline(radius:12))
     .overlay(PencilOutline(radius:12).stroke(PetAppearance.line.opacity(0.45),lineWidth:0.8).allowsHitTesting(false))
     .accessibilityIdentifier("local-session-card")
   }
  }
  PencilNoticeRegion(isPresented:!conversation.openNotice.isEmpty,identity:conversation.openNotice){Text(conversation.openNotice).font(PencilFont.text(12)).foregroundStyle(PetAppearance.accent)}
 }.accessibilityIdentifier("local-sessions-page")}
}

@MainActor private func watchedSessionItems(_ sessions:[CodexWatchedSession])->[LocalSessionItem] {
 sessions.map{session in
  let metadata=LocalConversationProvider.metadataOnly(session.id),provider=LocalConversationProvider.provider(session.id)
  let rawID=LocalConversationProvider.isDSH(session.id) ? session.id:metadata ? URL(fileURLWithPath:session.id).deletingPathExtension().lastPathComponent:(CodexThreadLink.url(forPath:session.id)?.lastPathComponent ?? session.id)
  return LocalSessionItem(provider:provider,ref:AgentEventNormalizer.sessionRef(provider:provider,sessionID:rawID),title:session.title,state:session.snapshot.state=="waiting_approval" ? .waiting_approval:.working,updatedAt:session.snapshot.updatedAt ?? .distantPast,sourcePath:session.id)
 }
}

struct AgentConnectionSettings:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var coordinator:AgentCoordinator
 @ObservedObject var conversation:CodexConversationMonitor
 var body:some View {VStack(alignment:.leading,spacing:12){
  Text(L10n.text("Agent 连接")).font(PencilFont.text(17))
  VStack(alignment:.leading,spacing:16){
   ForEach(coordinator.providers){provider in
    let health=connection(provider)
    VStack(alignment:.leading,spacing:8){
     HStack{Text(provider.title).font(PencilFont.text(16));Spacer();Text(health.status).font(PencilFont.text(12)).foregroundStyle(PetAppearance.accent)}
     Text(L10n.notice(provider.version)).font(PencilFont.text(11)).foregroundStyle(PetAppearance.secondary)
     Text(L10n.text("自动识别活跃会话，无需安装插件。")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
     PencilFeedback(message:health.notice,size:12)
     if health.canRetry {Button(L10n.text("重新检测 ")+provider.title){coordinator.refreshConnections();conversation.refreshConnections()}}
    }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(PetAppearance.surface,in:PencilOutline())
   }
   if !coordinator.codexThreads.isEmpty || coordinator.observedSessions.values.contains(where:{!$0.isEmpty}) {VStack(alignment:.leading,spacing:8){
    Text(L10n.text("向好友分享状态的会话"))
    Text(L10n.text("仅向你已授权的联系人分享状态。")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
    if !coordinator.codexThreads.isEmpty {Picker("Codex",selection:Binding(get:{coordinator.selectedCodexThread},set:{coordinator.selectSession(provider:"codex",ref:$0)})){Text(L10n.text("不分享")).tag("");ForEach(coordinator.codexThreads,id:\.self){id in Text(title("codex",id)).tag(id)}}}
    ForEach(["claude","deepseek"],id:\.self){provider in
     let refs=coordinator.observedSessions[provider] ?? []
     if !refs.isEmpty {Picker(agentProviderLabel(provider),selection:Binding(get:{coordinator.selectedSessions[provider] ?? ""},set:{coordinator.selectSession(provider:provider,ref:$0)})){Text(L10n.text("不分享")).tag("");ForEach(refs,id:\.self){ref in Text(title(provider,ref)).tag(ref)}}}
    }
   }.font(PencilFont.text(12))}
   PencilFeedback(message:coordinator.connectionNotice,size:12)
  }
 }.font(PencilFont.text(17)).accessibilityIdentifier("agent-connection-settings")}
 private func connection(_ provider:AgentProviderViewState)->AgentConnectionPresentation {
  let captured=LocalSessionPresentation.visible(watched:watchedSessionItems(conversation.activeSessions),events:coordinator.sessions,tracking:conversation.automaticEnabled).filter{$0.provider==provider.id}.count
  let connected=provider.id=="codex" && coordinator.codexConnected || provider.id=="claude" && coordinator.claudeConnected || provider.id=="deepseek" && coordinator.dshConnected || coordinator.sessions.contains{$0.provider==provider.id && $0.expiresAt>Date()}
  var issue=provider.id=="claude" ? conversation.claudeNotice:provider.id=="deepseek" ? conversation.dshNotice:""
  if provider.id=="codex",!coordinator.codexConnected {
   issue=conversation.codexNotice
   if issue.isEmpty,!conversation.codexConnected,captured==0{issue=coordinator.codexIssue}
  }
  if issue.isEmpty,!connected,captured==0{issue=coordinator.versionIssues[provider.id] ?? ""}
  return LocalSessionPresentation.connection(provider:provider.id,tracking:conversation.automaticEnabled,captured:captured,connected:connected,installed:![L10n.text("未安装"),L10n.text("检测中")].contains(L10n.notice(provider.version)),checking:L10n.notice(provider.version)==L10n.text("检测中") || coordinator.connectionsChecking || conversation.connectionsChecking,issue:issue)
 }
 private func title(_ provider:String,_ ref:String)->String {
  if let item=watchedSessionItems(conversation.sessions).first(where:{$0.provider==provider && ($0.ref==ref || CodexThreadLink.url(forPath:$0.sourcePath ?? "")?.lastPathComponent==ref)}){return item.title}
  return (provider=="deepseek" ? coordinator.dshTitles[ref]:coordinator.claudeTitles[ref]) ?? agentProviderLabel(provider)+L10n.text(" 会话")
 }
}
