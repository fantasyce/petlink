import Foundation
import SQLite3

@main struct CodexAutoSessionsTests {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  setenv("CODEX_HOME",root.path,1)
  let name="com.fantasyce.petlink.tests.auto-"+UUID().uuidString
  let defaults=UserDefaults(suiteName:name)!
  defer {defaults.removePersistentDomain(forName:name)}
  var db:OpaquePointer?;precondition(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path,&db)==SQLITE_OK)
  defer{sqlite3_close(db)}
  precondition(sqlite3_exec(db,"CREATE TABLE threads(id TEXT, rollout_path TEXT, title TEXT, archived INTEGER, updated_at INTEGER, name TEXT);",nil,nil,nil)==SQLITE_OK)
  func event(_ type:String,_ turn:String,date:Date=Date())->Data {
   var d=try! JSONSerialization.data(withJSONObject:["timestamp":ISO8601DateFormatter().string(from:date),"type":"event_msg","payload":["type":type,"turn_id":turn]]);d.append(10);return d
  }
  func add(_ id:String,_ title:String,_ content:Data,archived:Bool=false)throws->URL {
   let url=root.appendingPathComponent("rollout-"+id+".jsonl");try content.write(to:url)
   let sql="INSERT INTO threads VALUES ('\(id)','\(url.path)','\(title)',\(archived ? 1:0),\(Int(Date().timeIntervalSince1970)),NULL);"
   precondition(sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK);return url
  }
  func index(_ title:String)throws {var d=try JSONSerialization.data(withJSONObject:["id":"active-a","thread_name":title,"updated_at":ISO8601DateFormatter().string(from:Date())]);d.append(10);try d.write(to:root.appendingPathComponent("session_index.jsonl"))}
  let a=try add("active-a","DB title",event("task_started","a"))
  let b=try add("active-b","第二条执行中的对话",event("task_started","b"))
  precondition(sqlite3_exec(db,"UPDATE threads SET title='First prompt, not the title', name='第二条执行中的对话' WHERE id='active-b'",nil,nil,nil)==SQLITE_OK)
  var done=event("task_started","idle");done.append(event("task_complete","idle"));_ = try add("idle","空闲对话",done)
  _ = try add("stale","旧任务",event("task_started","old",date:Date().addingTimeInterval(-600)))
  _ = try add("archived","已归档",event("task_started","archived"),archived:true)
  _ = try add("unknown","仅修改文件",Data("{}\n".utf8))
  var internalTurn=try JSONSerialization.data(withJSONObject:["type":"session_meta","payload":["source":["subagent":["thread_spawn":["parent_thread_id":"qa-parent"]]]]])
  internalTurn.append(10);internalTurn.append(event("task_started","internal"));_ = try add("internal","",internalTurn)
  var largeInternal=try JSONSerialization.data(withJSONObject:["type":"session_meta","payload":["padding":String(repeating:"x",count:70000),"source":["subagent":["thread_spawn":["parent_thread_id":"qa-parent"]]]]])
  largeInternal.append(10);largeInternal.append(event("task_started","large-internal"));_ = try add("large-internal","",largeInternal)
  var largeUser=try JSONSerialization.data(withJSONObject:["type":"session_meta","payload":["padding":String(repeating:"x",count:70000),"source":"vscode"]])
  largeUser.append(10);largeUser.append(event("task_started","large-user"));_ = try add("large-user","大元数据用户对话",largeUser)
  precondition(CodexSessionDiscovery(home:root).scan().contains{$0.title=="大元数据用户对话"},"large user metadata must not be mistaken for an internal session")
  precondition(sqlite3_exec(db,"UPDATE threads SET archived=1 WHERE id='large-user'",nil,nil,nil)==SQLITE_OK)
  try index("真正的对话标题")
  let monitor=CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:root,listing:{[]},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]}))
  func wait(_ predicate:()->Bool)async {
   for _ in 0..<400 {monitor.refresh();if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
   preconditionFailure("automatic capture failed to settle")
  }
  await wait{monitor.sessions.count==2}
  precondition(Set(monitor.sessions.map(\.title))==["真正的对话标题","第二条执行中的对话"],"titles must match Codex metadata rather than hash suffixes")
  precondition(Set(monitor.activeSessions.map(\.id))==[a.path,b.path],"only executing sessions auto captured")
  try index("改名后的对话标题");await wait{monitor.sessions.contains{$0.title=="改名后的对话标题"}}
  let handle=try FileHandle(forWritingTo:a);try handle.seekToEnd();try handle.write(contentsOf:event("task_complete","a"));try handle.close()
  await wait{monitor.activeSessions.count==1}
  try? await Task.sleep(nanoseconds:8_500_000_000)
  await wait{monitor.sessions.count==1}
  precondition(monitor.sessions.first?.id==b.path,"completed auto capture removed after completion summary")
  monitor.stop();for _ in 0..<10 {monitor.refresh();try? await Task.sleep(nanoseconds:20_000_000)}
  precondition(monitor.sessions.isEmpty,"stop must not immediately recapture active sessions")
  monitor.automaticEnabled=true;await wait{monitor.sessions.count==1}
  precondition(monitor.sessions.first?.id==b.path,"re-enabling captures the still-running turn")
  let aborted=try FileHandle(forWritingTo:b);try aborted.seekToEnd();try aborted.write(contentsOf:event("turn_aborted","b"));try aborted.close()
  await wait{monitor.sessions.isEmpty}
  let restarted=try FileHandle(forWritingTo:a);try restarted.seekToEnd();try restarted.write(contentsOf:event("task_started","new-a"));try restarted.close()
  await wait{monitor.sessions.count==1}
  precondition(monitor.sessions.first?.title=="改名后的对话标题","a later turn in a retired session is recaptured")
  monitor.remove(a.path);try? await Task.sleep(nanoseconds:2_100_000_000);monitor.refresh();try? await Task.sleep(nanoseconds:100_000_000)
  precondition(monitor.sessions.isEmpty,"explicitly removed session is not immediately rediscovered")
  monitor.stop()
  print("Automatic active-only capture / titles / rename / terminal removal / stop PASS")
 }
}
