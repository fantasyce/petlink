import AppKit
import SwiftUI

struct CodexWatchedSession:Identifiable,Equatable {
 let id:String
 var title:String
 var snapshot=CodexConversationSnapshot()
 var status:String {
  switch snapshot.state {case "working":return L10n.text("进行中");case "waiting_approval":return L10n.text("等待回应");case "completed":return L10n.text("已完成");case "ended":return L10n.text("本轮已结束");case "cancelled":return L10n.text("已取消");default:return L10n.text("待确认")}
 }
}

@MainActor final class CodexConversationMonitor: ObservableObject {
 @Published private(set) var sessions:[CodexWatchedSession]=[]
 @Published var automaticEnabled:Bool {didSet{generation+=1;defaults.set(automaticEnabled,forKey:"codex-auto-active");if automaticEnabled {excludedIDs.removeAll();lastDiscovery = .distantPast}else{connectionsChecking=false;codexConnected=false;codexNotice="";claudeConnected=false;claudeNotice="";dshConnected=false;dshNotice="";claudeStatusChanged?([],false);dshStatusChanged?([],false);for id in sessions.map(\.id){remove(id)}};trackingChanged?(automaticEnabled);refresh()}}
 @Published var selectedID=""
 @Published var collapsed:Set<String>=[]
 @Published var allCollapsed=false {didSet{changed?(summary)}}
 @Published var bubblesEnabled:Bool {didSet{defaults.set(bubblesEnabled,forKey:"agent-bubbles");changed?(summary)}}
 @Published var completionEnabled:Bool {didSet{defaults.set(completionEnabled,forKey:"agent-completion-animation");changed?(summary)}}
 @Published private(set) var openNotice=""
 private var openNoticeGeneration=0
 @Published private(set) var notice=L10n.text("自动捕获正在执行的对话")
 @Published private(set) var claudeConnected=false
 @Published private(set) var claudeNotice=""
 @Published private(set) var codexConnected=false
 @Published private(set) var codexNotice=""
 @Published private(set) var dshConnected=false
 @Published private(set) var dshNotice=""
 private var timer:Timer?
 private var readers:[String:LocalConversationReader]=[:]
 private let defaults:UserDefaults
 private let pasteboard:NSPasteboard
 private let desktopOpener:(URL)->Bool
 @Published private(set) var connectionsChecking=false
 private let queue=DispatchQueue(label:"com.fantasyce.petlink.conversation",qos:.utility)
 private let discovery=CodexSessionDiscovery()
 private let claudeDiscovery:ClaudeSessionDiscovery
 private let dshDiscovery:DSHDesktopSessionDiscovery
 private var automaticIDs=Set<String>()
 private var excludedIDs=Set<String>()
 private var lastDiscovery=Date.distantPast
 private var reading=false
 private var generation=0
 private var activity=ConversationActivity()
 var claudeStatusChanged:(([CodexDiscoveredSession],Bool)->Void)?
 var dshStatusChanged:(([CodexDiscoveredSession],Bool)->Void)?
 var trackingChanged:((Bool)->Void)?
 var changed:((String)->Void)?
 var completed:(()->Void)?
 var selected:Bool {!sessions.isEmpty}
 var snapshot:CodexConversationSnapshot {sessions.first{$0.id==selectedID}?.snapshot ?? CodexConversationSnapshot()}
 var statusLabel:String {sessions.first{$0.id==selectedID}?.status ?? L10n.text("未选择会话")}
 var activeSessions:[CodexWatchedSession] {sessions.filter{activity.active[$0.id] != nil}}
 @Published private(set) var bubbleSessions:[CodexWatchedSession]=[]
 private func updateBubbleSessions(){
  let visible=activity.visible()
  let next=sessions.filter{visible[$0.id] != nil}
  if next != bubbleSessions {bubbleSessions=next}
 }
 var summary:String {selected ? L10n.text("{0} 个活跃 · {1} 个会话", activeSessions.count, sessions.count):""}
  init(defaults:UserDefaults,claudeDiscovery:ClaudeSessionDiscovery?=nil,dshDiscovery:DSHDesktopSessionDiscovery?=nil,pasteboard:NSPasteboard = .general,desktopOpener:@escaping(URL)->Bool={url in NSWorkspace.shared.urlForApplication(toOpen:url) != nil && NSWorkspace.shared.open(url)}){
  self.defaults=defaults;self.pasteboard=pasteboard;self.desktopOpener=desktopOpener;self.claudeDiscovery=claudeDiscovery ?? ClaudeSessionDiscovery();self.dshDiscovery=dshDiscovery ?? DSHDesktopSessionDiscovery()
  automaticEnabled=defaults.object(forKey:"codex-auto-active") as? Bool ?? true
  bubblesEnabled=defaults.object(forKey:"agent-bubbles") as? Bool ?? true
  completionEnabled=defaults.object(forKey:"agent-completion-animation") as? Bool ?? true
  // Old manual selections must not reopen conversation history on launch.
  defaults.removeObject(forKey:"codex-local-conversations")
  defaults.removeObject(forKey:"codex-local-conversation")
  timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in self?.refresh()}}
 }
 deinit{timer?.invalidate()}
 private func add(_ url:URL,title:String?=nil){
  let path=url.standardizedFileURL.resolvingSymlinksInPath().path
  guard !sessions.contains(where:{$0.id==path}),sessions.count<20 else{return}
  if !LocalConversationProvider.isDSH(path){readers[path]=LocalConversationReader(path:path)}
  sessions.append(.init(id:path,title:title ?? (LocalConversationProvider.isClaude(path) ? L10n.text("未命名对话"):discovery.title(for:path))))
  selectedID=path
 }
 func select(_ url:URL){generation+=1;let path=url.standardizedFileURL.resolvingSymlinksInPath().path;excludedIDs.remove(path);automaticIDs.remove(path);add(url);refresh()}
 func remove(_ id:String){generation+=1;excludedIDs.insert(id);automaticIDs.remove(id);readers.removeValue(forKey:id);sessions.removeAll{$0.id==id};activity.remove(id);collapsed.remove(id);if selectedID==id{selectedID=sessions.first?.id ?? ""};updateBubbleSessions();changed?(summary)}
 func stop(){automaticEnabled=false;for id in sessions.map(\.id){remove(id)};notice=L10n.text("已停止读取并清空本地预览")}
 func openInCodex(_ id:String){
   if let url=LocalConversationProvider.claudeDesktopURL(id) {
    showOpenNotice("")
    if !desktopOpener(url){showOpenNotice(L10n.text("无法打开 Claude Desktop，请确认桌面应用已安装"))}
    return
   }
  if LocalConversationProvider.isDSH(id) {
   showOpenNotice("")
   guard let url=URL(string:"dsh://open"),desktopOpener(url) else{showOpenNotice(L10n.text("无法打开 DeepSeek Harness，请确认桌面应用已安装"));return}
   return
  }
  if let command=LocalConversationProvider.resumeCommand(id) {
   selectedID=id;allCollapsed=false;collapsed.remove(id)
   pasteboard.clearContents();pasteboard.setString(command,forType:.string)
   showOpenNotice(L10n.text("会话命令已复制"),temporary:true);changed?(summary);return
  }
  showOpenNotice("")
  guard let url=CodexThreadLink.url(forPath:id) else{showOpenNotice(L10n.text("这份记录没有可打开的 Codex 对话 ID"));return}
  openCodexURL(url)
 }
 func openCodexThread(_ id:String){
  guard let uuid=UUID(uuidString:id),let url=URL(string:"codex://threads/"+uuid.uuidString.lowercased()) else{return}
  showOpenNotice("");openCodexURL(url)
 }
 private func openCodexURL(_ url:URL){
  guard NSWorkspace.shared.urlForApplication(toOpen:url) != nil,NSWorkspace.shared.open(url) else{showOpenNotice(L10n.text("无法打开 Codex，请确认桌面应用已安装"));return}
 }
 private func showOpenNotice(_ text:String,temporary:Bool=false){
  openNoticeGeneration+=1;openNotice=text
  guard temporary else{return}
  let token=openNoticeGeneration
  DispatchQueue.main.asyncAfter(deadline:.now()+2.5){[weak self] in
   guard let self,self.openNoticeGeneration==token else{return};self.openNotice=""
  }
 }
 func toggle(_ id:String){if collapsed.contains(id){collapsed.remove(id)}else{collapsed.insert(id)};changed?(summary)}
 func expandAll(){collapsed=[];allCollapsed=false;changed?(summary)}
 func refreshClaude(){lastDiscovery = .distantPast;refresh()}
 func refreshDSH(){lastDiscovery = .distantPast;refresh()}
 func refreshConnections(){generation+=1;connectionsChecking=automaticEnabled;lastDiscovery = .distantPast;refresh()}
 private func retire(_ id:String){
  readers.removeValue(forKey:id);sessions.removeAll{$0.id==id};activity.remove(id);automaticIDs.remove(id);collapsed.remove(id)
  if selectedID==id {selectedID=sessions.first?.id ?? ""}
 }
 func refresh(){
  guard !reading,automaticEnabled || !sessions.isEmpty else{return};reading=true
  let discover=automaticEnabled && Date().timeIntervalSince(lastDiscovery)>=2
  if discover {lastDiscovery=Date()}
  let epoch=generation,targets=sessions.filter{!LocalConversationProvider.metadataOnly($0.id)}.compactMap{session -> (String,LocalConversationReader)? in readers[session.id].map{(session.id,$0)}}
  queue.async{[weak self] in
   let claudeFound=discover ? (self?.claudeDiscovery.scan() ?? []):[]
   let claudeConnected=self?.claudeDiscovery.connected ?? false,claudeNotice=self?.claudeDiscovery.connectionNotice ?? ""
   let dshFound=discover ? (self?.dshDiscovery.scan() ?? []):[]
   let dshConnected=self?.dshDiscovery.connected ?? false,dshNotice=self?.dshDiscovery.connectionNotice ?? ""
   let found=discover ? (self?.discovery.scan() ?? [])+claudeFound+dshFound:[]
   let codexConnected=self?.discovery.connected ?? false,codexNotice=self?.discovery.connectionNotice ?? ""
   let results=targets.map{(id,reader) in (id,try? reader.poll(URL(fileURLWithPath:id)))}
   Task{@MainActor [weak self] in
    guard let self else{return};reading=false;guard generation==epoch else{return}
    var celebrate=false
    if discover {
     self.connectionsChecking=false
     self.codexConnected=codexConnected;self.codexNotice=codexNotice
     self.claudeConnected=claudeConnected;self.claudeNotice=claudeNotice
     claudeStatusChanged?(claudeFound,claudeConnected)
     self.dshConnected=dshConnected;self.dshNotice=dshNotice
     dshStatusChanged?(dshFound,dshConnected)
     let metadataIDs=Set((claudeFound+dshFound).map(\.path))
     for id in Array(automaticIDs) where LocalConversationProvider.metadataOnly(id) && !metadataIDs.contains(id) {
      retire(id)
     }
     for item in found where !excludedIDs.contains(item.path) {
      if let i=sessions.firstIndex(where:{$0.id==item.path}) {
       sessions[i].title=item.title
       if LocalConversationProvider.metadataOnly(item.path) {
        var snapshot=item.snapshot;snapshot.messages=[];sessions[i].snapshot=snapshot
        celebrate = activity.receive(snapshot,id:item.path) || celebrate
       }
      }
      else if sessions.count<20,["working","waiting_approval"].contains(item.snapshot.state) {
       let url=URL(fileURLWithPath:item.path);add(url,title:item.title);automaticIDs.insert(item.path)
       var snapshot=item.snapshot;snapshot.messages=[]
       if let i=sessions.firstIndex(where:{$0.id==item.path}) {sessions[i].title=item.title;sessions[i].snapshot=snapshot}
       _ = activity.receive(snapshot,id:item.path)
      }
     }
     notice=L10n.text("自动捕获正在执行的对话 · 仅在本机读取")
    }
    for (id,result) in results {
     guard let i=sessions.firstIndex(where:{$0.id==id}) else{continue}
     var value=result ?? CodexConversationSnapshot()
     value.messages=[]
     if value.state=="working",Date().timeIntervalSince(value.updatedAt ?? .distantPast)>120 {value.state="unknown"}
     let done=activity.receive(value,id:id)
     celebrate = celebrate || done
     if let title=readers[id]?.claude?.title {sessions[i].title=title}
     if sessions[i].snapshot != value {sessions[i].snapshot=value}
    }
    updateBubbleSessions()
    let visible=Set(bubbleSessions.map(\.id))
    for id in Array(automaticIDs) where !visible.contains(id) {
     // Retirement is not a user exclusion: a later turn can be captured again.
     retire(id)
    }
    changed?(summary)
    if celebrate && completionEnabled {completed?()}
   }
  }
 }
}

struct ConversationPreferences:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var monitor:CodexConversationMonitor
 var body:some View {VStack(alignment:.leading,spacing:8){
  Text(L10n.text("会话显示")).font(PencilFont.text(17))
  Toggle(L10n.text("显示会话气泡"),isOn:$monitor.bubblesEnabled).pencilFocusTarget("settings-bubbles")
  Toggle(L10n.text("完成时跳跃"),isOn:$monitor.completionEnabled).pencilFocusTarget("settings-completion")
 }.font(PencilFont.text(13))}
}

struct ConversationBubbles:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var monitor:CodexConversationMonitor
 var body:some View {
  VStack(spacing:0){
   if monitor.allCollapsed {
    Button(action:{monitor.expandAll()}){
     ZStack{
      Capsule().fill(PetAppearance.surface.opacity(0.65)).padding(.horizontal,10).offset(y:6)
      Capsule().fill(PetAppearance.surface.opacity(0.8)).padding(.horizontal,5).offset(y:3)
      HStack(spacing:6){
       Text(monitor.bubbleSessions.first?.title ?? L10n.text("会话")).lineLimit(1)
       Text("· \(monitor.bubbleSessions.count)").foregroundStyle(PetAppearance.secondary)
       Spacer(minLength:0)
      }.font(PencilFont.text(12)).padding(.horizontal,16).frame(height:26)
       .background(PetAppearance.surface,in:Capsule())
       .overlay(Capsule().stroke(PetAppearance.line.opacity(0.55),lineWidth:0.7))
     }.frame(height:26).padding(.horizontal,4).padding(.bottom,6)
    }.buttonStyle(.plain).accessibilityLabel(L10n.text("展开全部气泡")).help(L10n.text("展开全部气泡"))
   } else {
    ScrollView {
     VStack(spacing:8){
      ForEach(monitor.bubbleSessions){session in
       VStack(alignment:.leading,spacing:2){
         HStack(spacing:5){
          Image(systemName:session.snapshot.state=="completed" ? "checkmark.circle.fill":session.snapshot.state=="ended" ? "stop.circle":"ellipsis")
           .foregroundStyle(session.snapshot.state=="completed" ? Color.green:PetAppearance.secondary)
          Text(LocalConversationProvider.label(session.id)+" · "+session.title).font(PencilFont.text(12)).lineLimit(1)
         }
         if !monitor.collapsed.contains(session.id){
          Text(session.snapshot.progress.isEmpty ? L10n.text("等待最新进展…"):session.snapshot.progress)
           .font(.system(size:12)).lineLimit(1).foregroundStyle(PetAppearance.secondary)
         }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16)
         .frame(height:monitor.collapsed.contains(session.id) ? 30:56)
         .background(PetAppearance.surface,in:Capsule())
         .overlay(Capsule().stroke(PetAppearance.line.opacity(0.55),lineWidth:0.7))
        .contentShape(Capsule())
        .gesture(TapGesture(count:2).exclusively(before:TapGesture(count:1)).onEnded {value in
         switch value {case .first:monitor.openInCodex(session.id);case .second:monitor.toggle(session.id)}
        })
        .accessibilityElement(children:.ignore).accessibilityAddTraits(.isButton)
        .accessibilityLabel(session.title+L10n.text(" 气泡，单击折叠，双击")+LocalConversationProvider.openActionLabel(session.id))
        .accessibilityAction{monitor.toggle(session.id)}
        .accessibilityAction(named:Text(LocalConversationProvider.openActionLabel(session.id))){monitor.openInCodex(session.id)}
        .help(L10n.text("单击折叠或展开；双击")+LocalConversationProvider.openActionLabel(session.id))
        .overlay(PencilContextMenuAnchor{dismiss in
         Button(LocalConversationProvider.openActionLabel(session.id)){dismiss();monitor.openInCodex(session.id)}
         Button(L10n.text("全部收起")){dismiss();monitor.allCollapsed=true}
         Button(L10n.text("全部展开")){dismiss();monitor.expandAll()}
        })
      }
     }.padding(4)
    }.scrollIndicators(.hidden)
   }
  }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottom)
 }
}
