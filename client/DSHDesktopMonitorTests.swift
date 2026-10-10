import Foundation

@main struct DSHMonitorTests {
 final class Owners:@unchecked Sendable {
  private let lock=NSLock();private var live:[DSHDesktopSessionLease]=[]
  var delay:TimeInterval=0
  func set(_ live:[DSHDesktopSessionLease]){lock.lock();self.live=live;lock.unlock()}
  func read()->[DSHDesktopSessionLease]{lock.lock();let value=live,delay=self.delay;lock.unlock();if delay>0{Thread.sleep(forTimeInterval:delay)};return value}
 }
 @MainActor static func main()async throws {
  let requestedRoot=URL(fileURLWithPath:CommandLine.arguments[1])
  try FileManager.default.createDirectory(at:requestedRoot,withIntermediateDirectories:true)
  let root=requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  setenv("CODEX_HOME",root.path,1);setenv("CLAUDE_CONFIG_DIR",root.path,1)
  setenv("DSH_HOME",root.path,1)
  let suite="com.fantasyce.petlink.dsh-tests."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  let id="session-11111111-2222-3333-4444-555555555555",other="session-11111111-2222-3333-4444-555555555556"
  func lease(_ id:String)->DSHDesktopSessionLease{DSHDesktopSessionLease(lockPath:root.appendingPathComponent("sessions/project/"+id+"/session.lock").path,processIdentity:"test-live")}
  func write(_ id:String,_ open:Int?,_ title:String="自动捕获 DSH")throws {
   let url=root.appendingPathComponent("storages/session_projcache/sessions/"+id+".json")
   try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
   let value:[String:Any]=["version":7,"record":["identity":["formatVersion":4,"createdAt":1000],"rows":["title":["ver":1,"seq":8,"val":title],"turnBoundary":["ver":2,"seq":8,"val":["openTurnStartSeq":open.map{$0 as Any} ?? NSNull(),"lastTurn":1]]]]]
   try JSONSerialization.data(withJSONObject:value).write(to:url,options:.atomic)
  }
  try write(id,3);try write(other,nil,"空闲的历史")
  let owners=Owners();owners.set([lease(id),lease(other)])
  let monitor=CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:root,listing:{[]},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{owners.read()}))
  var completions=0;monitor.completed={completions+=1}
  func wait(_ stage:String,_ condition:()->Bool)async {for _ in 0..<250 {monitor.refreshClaude();if condition(){return};try? await Task.sleep(nanoseconds:20_000_000)};preconditionFailure("DSH monitor did not settle: \(stage)")}
  await wait("stage 1"){monitor.activeSessions.count==1}
  let path=root.appendingPathComponent("storages/session_projcache/sessions/"+id+".json").path
  precondition(monitor.activeSessions[0].title=="自动捕获 DSH" && monitor.activeSessions[0].snapshot.messages.isEmpty)
  precondition(LocalConversationProvider.label(path)=="DeepSeek Harness","DSH is identified throughout cards and bubbles")
  precondition(LocalConversationProvider.resumeCommand(path)==nil,"Desktop sessions must not generate a legacy CLI command")
  precondition(LocalConversationProvider.openActionLabel(path)=="打开 DeepSeek Harness")
  try write(id,3,"修改后的 DSH 名称");await wait("stage 2"){monitor.sessions[0].title=="修改后的 DSH 名称"}
  try write(id,nil);owners.set([]);await wait("stage 3"){monitor.activeSessions.isEmpty && monitor.bubbleSessions.first?.snapshot.state=="ended"}
  precondition(monitor.bubbleSessions.count==1)
  try? await Task.sleep(nanoseconds:8_500_000_000);await wait("stage 4"){monitor.sessions.isEmpty}
  precondition(completions==0,"a neutral turn end does not claim a successful answer")
  try write(id,3);owners.set([lease(id)]);await wait("stage 5"){monitor.activeSessions.count==1}
  owners.set([]);await wait("stage 6"){monitor.sessions.isEmpty}
  precondition(completions==0,"a crash never fires completion")
  owners.set([lease(id)]);await wait("stage 7"){monitor.activeSessions.count==1}
  monitor.automaticEnabled=false;precondition(monitor.sessions.isEmpty)
  monitor.automaticEnabled=true;await wait("stage 8"){monitor.activeSessions.count==1};monitor.automaticEnabled=false
  let delayed=Owners();delayed.delay=0.25;delayed.set([lease(id)])
  let stale=CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:root,listing:{[]},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{delayed.read()}))
  stale.automaticEnabled=true;stale.refreshClaude();stale.automaticEnabled=false
  try? await Task.sleep(nanoseconds:500_000_000)
  precondition(stale.sessions.isEmpty,"late discovery after tracking off must be discarded")
  precondition(LocalConversationProvider.resumeCommand(root.appendingPathComponent("storages/session_projcache/sessions/bad;cmd.json").path)==nil)
  print("DSH monitor: active-only, labels, titles, no transcript, terminal/crash, recapture, tracking off/on and stale results PASS")
 }
}
