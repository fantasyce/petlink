import Foundation
import Combine

@main struct ConversationMonitorTests {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  setenv("CODEX_HOME",root.path,1)
  let name="com.fantasyce.petlink.tests.multi-"+UUID().uuidString
  let defaults=UserDefaults(suiteName:name)!
  defer{defaults.removePersistentDomain(forName:name)}
  defaults.set(false,forKey:"codex-auto-active")
  func row(_ type:String,_ payload:[String:Any])->Data {
   let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
   var data=try! JSONSerialization.data(withJSONObject:["timestamp":formatter.string(from:Date()),"type":type,"payload":payload]);data.append(10);return data
  }
  func start(_ title:String)->Data {
   var data=row("event_msg",["type":"task_started","turn_id":title])
   data.append(row("response_item",["type":"message","role":"assistant","channel":"commentary","content":[["type":"output_text","text":title+" progress"]]]));return data
  }
  func append(_ url:URL,_ data:Data)throws {let h=try FileHandle(forWritingTo:url);defer{try? h.close()};try h.seekToEnd();try h.write(contentsOf:data)}
  let a=root.appendingPathComponent("qa-alpha.jsonl"),b=root.appendingPathComponent("qa-beta.jsonl")
  try start("alpha").write(to:a);try start("beta").write(to:b)
  let monitor=CodexConversationMonitor(defaults:defaults,dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]}))
  precondition(monitor.bubblesEnabled && monitor.completionEnabled,"default enabled")
  var celebrations=0;monitor.completed={celebrations+=1}
  monitor.select(a);monitor.select(b)
  func wait(_ predicate:()->Bool)async {
   for _ in 0..<300 {monitor.refresh();if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)}
   preconditionFailure("monitor did not settle")
  }
  await wait{monitor.activeSessions.count==2}
  precondition(monitor.sessions.allSatisfy{$0.snapshot.messages.isEmpty},"UI session snapshots must not retain conversation history")
  precondition(Set(monitor.activeSessions.map{$0.snapshot.progress})==["alpha progress","beta progress"],"real readers must not cross session contents")
  precondition(celebrations==0,"initial replay silent")
  monitor.toggle(a.path);precondition(monitor.collapsed==[a.path],"individual collapse isolated")
  monitor.allCollapsed=true;monitor.expandAll();precondition(!monitor.allCollapsed && monitor.collapsed.isEmpty,"expand all restores all cards")
  try append(a,row("event_msg",["type":"task_complete","turn_id":"alpha"]))
  await wait{monitor.activeSessions.count==1}
  precondition(celebrations==1,"one live completion")
  monitor.refresh();try? await Task.sleep(nanoseconds:100_000_000)
  precondition(celebrations==1,"repeat poll does not replay")
  var visibleIDs:[String]=[]
  let observation=monitor.$bubbleSessions.sink{visibleIDs=$0.map(\.id)}
  precondition(visibleIDs.contains(a.path),"completed summary published to UI")
  try? await Task.sleep(nanoseconds:8_300_000_000)
  await wait{monitor.bubbleSessions.count==1}
  precondition(visibleIDs==[b.path],"expiry publishes a UI update while another session stays active")
  observation.cancel()
  try append(b,row("event_msg",["type":"turn_aborted","turn_id":"beta"]))
  await wait{monitor.activeSessions.isEmpty}
  precondition(celebrations==1,"cancel must not celebrate")
  monitor.bubblesEnabled=false;monitor.completionEnabled=false
  let restored=CodexConversationMonitor(defaults:defaults,dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]}))
  precondition(!restored.bubblesEnabled && !restored.completionEnabled && restored.sessions.isEmpty,"display preferences restore without reopening manually selected history")
  try append(a,start("second"));await wait{monitor.activeSessions.count==1}
  try append(a,row("event_msg",["type":"task_complete","turn_id":"second"]))
  await wait{monitor.activeSessions.isEmpty};precondition(celebrations==1,"disabled animation stays silent")
  monitor.remove(a.path);precondition(monitor.sessions.count==1,"remove selected source")
  monitor.automaticEnabled=false
  precondition(monitor.sessions.isEmpty && monitor.activeSessions.isEmpty,"turning tracking off clears every captured source and stops reading")
  monitor.stop();precondition(monitor.sessions.isEmpty && monitor.activeSessions.isEmpty,"stop clears all content")
  print("Real multi-reader monitor / progress isolation / completion callback / cancel / settings restart / stop PASS")
  print("Task-owned preference suite:",name)
 }
}
