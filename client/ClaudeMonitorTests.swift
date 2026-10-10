import Foundation
@main struct ClaudeMonitorTests {
 final class Listing:@unchecked Sendable {
  private let lock=NSLock()
  private var rows:[ClaudeLiveSession]=[]
  private var failure=false
  var delay:TimeInterval=0
  func set(_ rows:[ClaudeLiveSession],failed:Bool=false){lock.lock();self.rows=rows;failure=failed;lock.unlock()}
  func read()throws->[ClaudeLiveSession]{lock.lock();let rows=self.rows,failed=failure,delay=self.delay;lock.unlock();if delay>0{Thread.sleep(forTimeInterval:delay)};if failed{throw CocoaError(.fileReadCorruptFile)};return rows}
 }
 @MainActor static func main()async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
  let project=root.appendingPathComponent("projects/petlink");try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
  setenv("CLAUDE_CONFIG_DIR",root.path,1);setenv("CODEX_HOME",root.path,1)
  let suite="com.fantasyce.petlink.claude-tests."+UUID().uuidString;let defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
  let id="11111111-2222-3333-4444-555555555555",waitingID="11111111-2222-3333-4444-555555555556"
  let file=project.appendingPathComponent(id+".jsonl")
  func append(_ row:[String:Any])throws {var data=try JSONSerialization.data(withJSONObject:row);data.append(10);if !FileManager.default.fileExists(atPath:file.path){try data.write(to:file)}else{let handle=try FileHandle(forWritingTo:file);try handle.seekToEnd();try handle.write(contentsOf:data);try handle.close()}}
  func session(_ id:String,status:String,name:String?=nil)->ClaudeLiveSession{ClaudeLiveSession(kind:"interactive",cwd:"/qa/petlink",sessionId:id,name:name,pid:123,status:status,state:nil,waitingFor:status=="waiting" ? "input needed":nil)}
  try append(["type":"user","timestamp":ISO8601DateFormatter().string(from:Date().addingTimeInterval(-600)),"message":["content":"Claude active title"]])
  try append(["type":"assistant","message":["content":"Old completed reply","stop_reason":"end_turn"]])
  try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-600)],ofItemAtPath:file.path)
  let listing=Listing();listing.set([session(id,status:"busy",name:"petlink-3f"),session(waitingID,status:"waiting",name:"等待输入的会话"),session("11111111-2222-3333-4444-555555555557",status:"idle")])
  let monitor=CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:root,listing:{try listing.read()},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]}));var completions=0;monitor.completed={completions+=1}
  func wait(_ condition:()->Bool)async {for _ in 0..<450{monitor.refreshClaude();if condition(){return};try? await Task.sleep(nanoseconds:10_000_000)};preconditionFailure("Claude monitor did not settle")}
  await wait{monitor.activeSessions.count==2}
  precondition(monitor.sessions.first{$0.id==file.path}?.title=="Claude active title" && completions==0,"old transcript and default directory code cannot decide live activity or title")
  precondition(monitor.activeSessions.contains{$0.snapshot.state=="waiting_approval"},"waiting stays visible without a transcript or hook")
  precondition(monitor.claudeConnected && monitor.sessions.allSatisfy{$0.snapshot.messages.isEmpty && !$0.snapshot.progress.contains("Old completed reply")},"official status UI stores no transcript")
  try append(["type":"custom-title","customTitle":"Renamed Claude conversation"])
  await wait{monitor.sessions.first{$0.id==file.path}?.title=="Renamed Claude conversation"}
  listing.set([session(id,status:"idle")])
  await wait{completions==1 && monitor.activeSessions.isEmpty}
  precondition(monitor.bubbleSessions.count==1,"completion remains briefly; exited waiting session disappears")
  try? await Task.sleep(nanoseconds:8_500_000_000);await wait{monitor.sessions.isEmpty}
  precondition(completions==1,"unchanged idle does not replay completion")
  listing.set([session(id,status:"busy")]);await wait{monitor.activeSessions.count==1}
  listing.set([],failed:true);await wait{monitor.sessions.isEmpty && !monitor.claudeConnected}
  precondition(!monitor.claudeNotice.isEmpty,"unsupported query gives a retry/upgrade notice, no file or Hook fallback")
  listing.set([session(id,status:"busy")]);await wait{monitor.activeSessions.count==1}
  listing.set([]);await wait{monitor.sessions.isEmpty && monitor.claudeConnected}
  listing.set([session(id,status:"busy")]);await wait{monitor.sessions.count==1}
  monitor.stop();try? await Task.sleep(nanoseconds:150_000_000);precondition(monitor.sessions.isEmpty && !monitor.claudeConnected)
  monitor.automaticEnabled=true;await wait{monitor.sessions.count==1}
  monitor.remove(file.path);try? await Task.sleep(nanoseconds:150_000_000);monitor.refreshClaude();try? await Task.sleep(nanoseconds:150_000_000);precondition(monitor.sessions.isEmpty)
  precondition(LocalConversationProvider.resumeCommand(file.path)=="claude --resume "+id)
  precondition(LocalConversationProvider.resumeCommand("/tmp/invalid;cmd.jsonl")==nil)
  monitor.stop()
  let delayed=Listing();delayed.delay=0.2;delayed.set([session(id,status:"busy")])
  let stale=CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:root,listing:{try delayed.read()},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]}))
  stale.automaticEnabled=true;stale.refreshClaude();stale.automaticEnabled=false
  try? await Task.sleep(nanoseconds:400_000_000)
  precondition(stale.sessions.isEmpty && !stale.claudeConnected,"late query result after tracking off must be discarded")
  print("Claude no-hook monitor: official busy/waiting/idle, stale transcript, multi-session, titles, no history, completion, exit, failure, recapture, stop, stale-query discard PASS")
 }
}
