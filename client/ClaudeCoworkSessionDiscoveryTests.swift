import Foundation

@main struct ClaudeCoworkSessionDiscoveryTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:root)}
  let sessions=root.appendingPathComponent("Claude-3p/local-agent-mode-sessions"),org=sessions.appendingPathComponent("account/org")
  let local="local_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",cli="11111111-2222-4333-8444-555555555555"
  let metadata=org.appendingPathComponent(local+".json"),runtime=org.appendingPathComponent("aaaaaaaa/.claude")
  let registry=runtime.appendingPathComponent("sessions/123.json"),transcript=runtime.appendingPathComponent("projects/session/"+cli+".jsonl")
  try FileManager.default.createDirectory(at:registry.deletingLastPathComponent(),withIntermediateDirectories:true)
  try FileManager.default.createDirectory(at:transcript.deletingLastPathComponent(),withIntermediateDirectories:true)
  func check(_ value:Bool,_ message:String){if !value{fputs(message+"\n",stderr);exit(1)}}
  func writeMetadata(_ archived:Bool=false) throws {
   try JSONSerialization.data(withJSONObject:["sessionId":local,"cliSessionId":cli,"title":"Cowork 双端验收","isArchived":archived,"hostLoopMode":true,"initialMessage":"Private prompt must not be retained","systemPrompt":"Private system text must not be retained"]).write(to:metadata)
  }
  func status(_ value:String,_ pid:Int=123,_ id:String?=nil) throws {
   try JSONSerialization.data(withJSONObject:["pid":pid,"sessionId":id ?? cli,"kind":"interactive","entrypoint":"local-agent","pidDomain":"darwin","procStart":"Fri Oct  9 07:30:23 2026","status":value,"cwd":"/sessions/test","updatedAt":1791531023000]).write(to:registry)
  }
  func event(_ type:String,_ text:String,_ stop:String?=nil) throws {
   var message:[String:Any]=["content":[["type":"text","text":text]]];if let stop{message["stop_reason"]=stop}
   let data=try JSONSerialization.data(withJSONObject:["type":type,"uuid":UUID().uuidString,"timestamp":"2026-10-09T07:30:30Z","message":message])+Data([10])
   if FileManager.default.fileExists(atPath:transcript.path){let h=try FileHandle(forWritingTo:transcript);defer{try? h.close()};try h.seekToEnd();try h.write(contentsOf:data)}else{try data.write(to:transcript)}
  }
  try writeMetadata();try status("idle");try event("assistant","Old completed answer","end_turn")
  var processAlive=true
  let discovery=ClaudeCoworkSessionDiscovery(roots:[sessions],processMatches:{pid,start in processAlive && pid==123 && start=="Fri Oct  9 07:30:23 2026"})
  check(discovery.scan().isEmpty,"Idle Cowork history must not create a bubble")
  try event("user","New private prompt");try status("busy")
  let found=discovery.scan()
  check(found.count==1 && found[0].path==metadata.path && found[0].snapshot.state=="working","Cowork's isolated runtime must be captured without a global CLI listing")
  check(found[0].title=="Cowork 双端验收" && found[0].snapshot.messages.isEmpty && !found[0].snapshot.progress.contains("private"),"Only the Cowork metadata title and coarse state may reach PetLink")
  let combined=ClaudeSessionDiscovery(home:root,listing:{throw CocoaError(.fileNoSuchFile)},desktopRoots:[],coworkDiscovery:discovery)
  check(combined.scan().first?.path==metadata.path && combined.connected,"Cowork tracking must work even when the separate global Code CLI is unavailable")
  let duplicate=ClaudeLiveSession(kind:"interactive",cwd:"/sessions/test",sessionId:cli,name:"generated-name",pid:123,status:"busy",state:nil,waitingFor:nil)
  let combinedListing=ClaudeSessionDiscovery(home:root,listing:{[duplicate]},desktopRoots:[],coworkDiscovery:discovery)
  check(combinedListing.scan().count==1,"A Cowork runtime also present in the global listing must not create a duplicate Code bubble")
  try status("waiting");check(discovery.scan().first?.snapshot.state=="waiting_approval","Cowork waiting state stays active")
  try event("assistant","Private answer","end_turn");try status("idle")
  check(discovery.scan().first?.snapshot.state=="completed","Only a fresh final answer can complete the observed Cowork turn")
  check(discovery.scan(now:Date().addingTimeInterval(9)).isEmpty,"Idle Cowork completion must disappear and not replay")
  try event("user","Next prompt");try status("busy");check(discovery.scan().count==1,"A later Cowork turn is captured again")
  try event("user","[Request interrupted by user]");try status("idle")
  check(discovery.scan().first?.snapshot.state=="cancelled","Cowork Stop must not be celebrated as successful completion")
  try status("busy");_ = discovery.scan();processAlive=false
  check(discovery.scan().isEmpty,"A dead or reused process must remove an unfinished Cowork bubble")
  processAlive=true;try status("busy",999);check(discovery.scan().isEmpty,"Unverified registry PIDs must not count as live tasks")
  try status("busy",123,"99999999-2222-4333-8444-555555555555");check(discovery.scan().isEmpty,"A registry from another CLI session cannot bind to this conversation")
  try status("busy");try writeMetadata(true);check(discovery.scan().isEmpty,"Archived Cowork tasks must disappear")
  try writeMetadata();try status("future-status");check(discovery.scan().isEmpty,"Unknown activity contracts must fail closed")
  let future=ClaudeSessionDiscovery(home:root,listing:{[]},desktopRoots:[],coworkDiscovery:discovery)
  _ = future.scan();check(!future.connectionNotice.isEmpty,"A changed live Cowork contract must report compatibility failure instead of healthy idle")
  try status("busy");let outside=root.appendingPathComponent("outside.json");try Data(contentsOf:registry).write(to:outside);try FileManager.default.removeItem(at:registry);try FileManager.default.createSymbolicLink(at:registry,withDestinationURL:outside)
  check(discovery.scan().isEmpty,"Symlinked runtime status must not escape the Cowork session boundary")
  print("Cowork isolated discovery: idle/busy/waiting/complete/stop/exit/archive/privacy/boundaries PASS")
 }
}
