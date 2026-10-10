import Foundation

@main struct DSHDesktopSessionDiscoveryTests {
 static func main()throws {
  let requestedRoot=URL(fileURLWithPath:CommandLine.arguments[1])
  try FileManager.default.createDirectory(at:requestedRoot,withIntermediateDirectories:true)
  let root=requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
  let fm=FileManager.default,home=root.appendingPathComponent("home"),id="session-11111111-2222-3333-4444-555555555555"
  let lock=home.appendingPathComponent("sessions/project/"+id+"/session.lock")
  let file=home.appendingPathComponent("storages/session_projcache/sessions/"+id+".json")
  try fm.createDirectory(at:lock.deletingLastPathComponent(),withIntermediateDirectories:true)
  try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
  try Data().write(to:lock)
  var live=[DSHDesktopSessionLease(lockPath:lock.path,processIdentity:"test-process-start-1")]
  let discovery=DSHDesktopSessionDiscovery(leases:{live})
  var version=7,boundaryVersion=2,created:Double=1000,title="DSH 会话标题",seq=8,turn=1
  func write(_ open:Int?)throws {
   let value:[String:Any]=["version":version,"record":["identity":["formatVersion":4,"createdAt":created,"cwd":"/private/not-to-be-opened"],"rows":["title":["ver":1,"seq":seq,"val":title],"turnBoundary":["ver":boundaryVersion,"seq":seq,"val":["openTurnStartSeq":open.map{$0 as Any} ?? NSNull(),"lastTurn":turn]],"titleInput":["val":["first":["text":"secret transcript that must not appear"]]]]]]
   try JSONSerialization.data(withJSONObject:value).write(to:file,options:.atomic)
  }
  try write(3)
  let now=Date(timeIntervalSince1970:2000)
  let active=discovery.scan(now:now)
  precondition(active.count==1 && active[0].title==title && active[0].snapshot.state=="working","live writer with an open DSH turn must be captured")
  precondition(active[0].snapshot.messages.isEmpty && !active[0].snapshot.progress.contains("secret"),"only allowlisted metadata may reach PetLink")
  precondition(discovery.connected && discovery.decodedFiles==1)
  precondition(discovery.scan(now:now.addingTimeInterval(500)).count==1 && discovery.decodedFiles==1,"unchanged metadata is reused; a long live turn is not mistaken for an idle session")
  live=[DSHDesktopSessionLease(lockPath:lock.path,processIdentity:"restarted-after-cache",startedAt:Date().addingTimeInterval(60))]
  precondition(discovery.scan(now:now).isEmpty,"a new process loading a cache from before its own start cannot revive a crashed turn")
  live=[DSHDesktopSessionLease(lockPath:lock.path,processIdentity:"test-process-start-1")]
  precondition(discovery.scan(now:now).count==1)
  title="修改后的 DSH 标题";seq=9;try write(3)
  precondition(discovery.scan(now:now)[0].title==title && discovery.decodedFiles==2,"atomic metadata replacement updates the title")
  title=String(repeating:"长",count:5000);seq=10;try write(3)
  precondition(discovery.scan(now:now)[0].title.count==200 && discovery.retainedTitleCharacters==200,"long titles are bounded in both UI and retained metadata")
  title="a"+String(repeating:"\u{0301}",count:5000);seq=11;try write(3)
  _ = discovery.scan(now:now)
  precondition(discovery.retainedTitleBytes<=2048,"combining marks cannot bypass the retained title byte limit")
  seq=12;try write(nil);live=[]
  let ended=discovery.scan(now:now)
  precondition(ended.count==1 && ended[0].snapshot.state=="ended" && ended[0].snapshot.completionID != nil,"a final closed turn survives writer exit as a neutral end, without claiming success")
  let completion=ended[0].snapshot.completionID
  precondition(discovery.scan(now:now.addingTimeInterval(9)).isEmpty,"completed sessions are retired")
  live=[DSHDesktopSessionLease(lockPath:lock.path,processIdentity:"test-process-start-2")]
  precondition(discovery.scan(now:now).isEmpty,"loading an idle history never creates a card")
  turn=2;seq=20;try write(18)
  precondition(discovery.scan(now:now).count==1)
  live=[]
  precondition(discovery.scan(now:now).isEmpty,"a dead writer with stale openTurn metadata is a crash, not activity or completion")
  live=[DSHDesktopSessionLease(lockPath:lock.path,processIdentity:"test-process-start-3")];created=3000;turn=1;seq=5;try write(2)
  precondition(discovery.scan(now:now).count==1)
  seq=7;try write(nil)
  precondition(discovery.scan(now:now)[0].snapshot.completionID != completion,"a replaced session cannot replay the old completion token")
  let untitled:[String:Any]=["version":7,"record":["identity":["formatVersion":4,"createdAt":1000],"rows":["title":["ver":1,"seq":3,"val":NSNull()],"turnBoundary":["ver":2,"seq":3,"val":["openTurnStartSeq":NSNull(),"lastTurn":0]]]]]
  try JSONSerialization.data(withJSONObject:untitled).write(to:file,options:.atomic)
  _=discovery.scan(now:now)
  precondition(discovery.connectionNotice.isEmpty && discovery.connected,"a newly created Desktop session with null title is healthy idle metadata")
  var empty=untitled
  var record=empty["record"] as! [String:Any],rows=record["rows"] as! [String:Any]
  rows["title"]=["ver":1,"seq":-1,"val":NSNull()]
  rows["turnBoundary"]=["ver":2,"seq":-1,"val":["openTurnStartSeq":NSNull(),"lastTurn":0]]
  record["rows"]=rows;empty["record"]=record
  try JSONSerialization.data(withJSONObject:empty).write(to:file,options:.atomic)
  _=discovery.scan(now:now)
  precondition(discovery.connectionNotice.isEmpty && discovery.connected,"Desktop initial projection watermark -1 with a closed turn is healthy idle")
  let legacy:[String:Any]=["version":7,"record":["identity":["createdAt":1000],"rows":["title":["ver":0,"seq":1,"val":["old":"shape"]],"turnBoundary":["ver":1,"seq":1,"val":[:]]]]]
  try JSONSerialization.data(withJSONObject:legacy).write(to:file,options:.atomic)
  _=discovery.scan(now:now)
  precondition(discovery.connectionNotice.isEmpty,"formatless historical caches loaded by Desktop are ignored rather than reported as a connection failure")
  version=99;try write(2)
  precondition(discovery.scan(now:now).isEmpty && !discovery.connectionNotice.isEmpty,"unknown cache formats fail closed with an actionable notice")
  version=7;boundaryVersion=99;try write(2)
  precondition(discovery.scan(now:now).isEmpty,"unknown activity projections are never guessed")
  boundaryVersion=2;try write(2)
  try fm.removeItem(at:file);try fm.createSymbolicLink(at:file,withDestinationURL:root.appendingPathComponent("outside.json"))
  precondition(discovery.scan(now:now).isEmpty,"projection symlinks cannot redirect reads")
  try fm.removeItem(at:file);try Data(repeating:65,count:1_048_577).write(to:file)
  precondition(discovery.scan(now:now).isEmpty,"oversized state files are bounded")
  live=[DSHDesktopSessionLease(lockPath:home.appendingPathComponent("other/project/"+id+"/session.lock").path,processIdentity:"fake")]
  precondition(discovery.scan(now:now).isEmpty,"an unrelated lock layout cannot identify a DSH home")
  print("DSH discovery: live-only, incremental metadata, titles, no history, terminal/exit/crash, replacement, version and filesystem bounds PASS")
 }
}
