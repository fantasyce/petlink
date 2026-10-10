import Foundation
import SQLite3

// Exercise the shared monitor with all providers present, rather than testing
// each adapter in isolation. Every path, status source and preference is owned
// by this test; no running user conversation is queried or modified.
@main struct MultiProviderMonitorTests {
 final class LiveSources: @unchecked Sendable {
  private let lock=NSLock()
  private var claude:[ClaudeLiveSession]=[]
  private var dsh:[DSHDesktopSessionLease]=[]
  func set(claude:[ClaudeLiveSession],dsh:[DSHDesktopSessionLease]){lock.lock();self.claude=claude;self.dsh=dsh;lock.unlock()}
  func claudeRows()->[ClaudeLiveSession]{lock.lock();defer{lock.unlock()};return claude}
  func dshRows()->[DSHDesktopSessionLease]{lock.lock();defer{lock.unlock()};return dsh}
 }
 @MainActor static func main() async throws {
  let requested=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:requested,withIntermediateDirectories:true)
  let root=requested.standardizedFileURL.resolvingSymlinksInPath()
  defer{try? FileManager.default.removeItem(at:root)}
  setenv("CODEX_HOME",root.path,1);setenv("CLAUDE_CONFIG_DIR",root.path,1);setenv("DSH_HOME",root.path,1)
  let suite="com.fantasyce.petlink.multi-provider-tests."+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer{defaults.removePersistentDomain(forName:suite)}
  var db:OpaquePointer?
  precondition(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path,&db)==SQLITE_OK)
  defer{sqlite3_close(db)}
  precondition(sqlite3_exec(db,"CREATE TABLE threads(id TEXT, rollout_path TEXT, title TEXT, archived INTEGER, updated_at INTEGER);",nil,nil,nil)==SQLITE_OK)
  let codex=root.appendingPathComponent("rollout-concurrent.jsonl")
  func event(_ type:String,_ turn:String)throws->Data {
   var data=try JSONSerialization.data(withJSONObject:["timestamp":ISO8601DateFormatter().string(from:Date()),"type":"event_msg","payload":["type":type,"turn_id":turn]])
   data.append(10);return data
  }
  func append(_ type:String,_ turn:String)throws {
   let handle=try FileHandle(forWritingTo:codex);defer{try? handle.close()}
   try handle.seekToEnd();try handle.write(contentsOf:event(type,turn))
  }
  try event("task_started","codex-0").write(to:codex)
  precondition(sqlite3_exec(db,"INSERT INTO threads VALUES ('concurrent','\(codex.path)','Codex 并发',0,\(Int(Date().timeIntervalSince1970)));",nil,nil,nil)==SQLITE_OK)
  let claudeID="11111111-2222-3333-4444-555555555555"
  let claude=root.appendingPathComponent("projects/concurrent/"+claudeID+".jsonl")
  try FileManager.default.createDirectory(at:claude.deletingLastPathComponent(),withIntermediateDirectories:true)
  var claudeTitle=try JSONSerialization.data(withJSONObject:["type":"custom-title","customTitle":"Claude 并发"]);claudeTitle.append(10);try claudeTitle.write(to:claude)
  func claudeRow(_ state:String)->ClaudeLiveSession{ClaudeLiveSession(kind:"interactive",cwd:root.path,sessionId:claudeID,name:"Claude 并发",pid:123,status:state,state:nil,waitingFor:nil)}
  let dshID="session-11111111-2222-3333-4444-555555555555"
  let dsh=root.appendingPathComponent("storages/session_projcache/sessions/"+dshID+".json")
  let lease=DSHDesktopSessionLease(lockPath:root.appendingPathComponent("sessions/concurrent/"+dshID+"/session.lock").path,processIdentity:"task-owned-live")
  func writeDSH(open:Int?)throws {
   try FileManager.default.createDirectory(at:dsh.deletingLastPathComponent(),withIntermediateDirectories:true)
   let value:[String:Any]=["version":7,"record":["identity":["formatVersion":4,"createdAt":1000],"rows":["title":["ver":1,"seq":8,"val":"DSH 并发"],"turnBoundary":["ver":2,"seq":8,"val":["openTurnStartSeq":open.map{$0 as Any} ?? NSNull(),"lastTurn":1]]]]]
   try JSONSerialization.data(withJSONObject:value).write(to:dsh,options:.atomic)
  }
  try writeDSH(open:3)
  let sources=LiveSources();sources.set(claude:[claudeRow("busy")],dsh:[lease])
  let monitor=CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:root,listing:{sources.claudeRows()},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{sources.dshRows()}))
  defer{monitor.stop()}
  var completions=0;monitor.completed={completions+=1}
  func wait(_ stage:String,_ predicate:()->Bool)async {
   for _ in 0..<500 {monitor.refresh();monitor.refreshClaude();if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
   preconditionFailure("shared monitor did not settle: \(stage)")
  }
  await wait("all providers active"){monitor.activeSessions.count==3}
  precondition(Set(monitor.activeSessions.map(\.title))==["Codex 并发","Claude 并发","DSH 并发"])
  precondition(monitor.sessions.allSatisfy{$0.snapshot.messages.isEmpty},"shared UI must not retain transcripts")
  precondition(completions==0,"initial capture is silent")
  try append("task_complete","codex-0")
  await wait("Codex ends independently"){Set(monitor.activeSessions.map(\.title))==["Claude 并发","DSH 并发"]}
  precondition(completions==1,"only Codex completed")
  sources.set(claude:[claudeRow("idle")],dsh:[lease])
  await wait("Claude ends independently"){monitor.activeSessions.count==1 && monitor.activeSessions.first?.title=="DSH 并发"}
  precondition(completions==2,"Claude completion must not duplicate Codex")
  try writeDSH(open:nil);sources.set(claude:[],dsh:[])
  await wait("neutral DSH end"){monitor.activeSessions.isEmpty}
  precondition(completions==2,"DSH neutral end must not claim success")
  for turn in 1...30 {
   try append("task_started","codex-\(turn)");try writeDSH(open:3)
   sources.set(claude:[claudeRow("busy")],dsh:[lease])
   monitor.automaticEnabled=false
   precondition(monitor.sessions.isEmpty && monitor.activeSessions.isEmpty)
   monitor.automaticEnabled=true
   await wait("recapture \(turn)"){monitor.activeSessions.count==3}
   try append("turn_aborted","codex-\(turn)")
   sources.set(claude:[],dsh:[])
   await wait("cancel \(turn)"){monitor.sessions.isEmpty}
  }
  precondition(completions==2,"exit/cancel and recapture must not replay completion")
  // A turn entirely between discovery passes cannot be shown as currently
  // working after it has already finished. This is the polling boundary.
  try append("task_started","too-short");try append("task_complete","too-short")
  monitor.refresh();try? await Task.sleep(nanoseconds:250_000_000)
  precondition(monitor.activeSessions.isEmpty && completions==2)
  print("Three-provider shared monitor: simultaneous titles/no history, independent terminals, 30 off/on/recapture/cancel cycles, short-turn boundary PASS")
 }
}
