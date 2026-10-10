import Foundation

@main struct ClaudeDesktopIntegrationTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:root)}
  let desktop=root.appendingPathComponent("Claude-3p/claude-code-sessions")
  let storage=desktop.appendingPathComponent("account/org"),project=root.appendingPathComponent("projects/workspace")
  try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
  let cli="11111111-2222-4333-8444-555555555555",local="local_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  let record=storage.appendingPathComponent(local+".json"),transcript=project.appendingPathComponent(cli+".jsonl")
  func check(_ value:Bool,_ message:String){if !value{fputs(message+"\n",stderr);exit(1)}}
  func metadata(_ archived:Bool=false,title:String="桌面会话验收") throws {try JSONSerialization.data(withJSONObject:["sessionId":local,"cliSessionId":cli,"title":title,"lastActivityAt":1791000000000,"isArchived":archived,"spawnSeed":["message":"Not retained"]]).write(to:record)}
  func event(_ type:String,_ stop:String?=nil,_ text:String="Test content") throws {
   var message:[String:Any]=["content":[["type":"text","text":text]]];if let stop{message["stop_reason"]=stop}
   let row:[String:Any]=["type":type,"uuid":"turn-finished","timestamp":"2026-10-03T04:00:00Z","message":message]
   let data=try JSONSerialization.data(withJSONObject:row)+Data([10])
   if FileManager.default.fileExists(atPath:transcript.path){let h=try FileHandle(forWritingTo:transcript);defer{try? h.close()};try h.seekToEnd();try h.write(contentsOf:data)}else{try data.write(to:transcript)}
  }
  try metadata()
  let index=ClaudeDesktopSessionIndex(roots:[desktop]);check(index.records()[cli]?.path==record.path,"Desktop's local ID must map to the registered CLI ID")
  check(index.records()[cli]?.title=="桌面会话验收","Use the Desktop conversation title")
  let row=ClaudeLiveSession(kind:"interactive",cwd:"/workspace",sessionId:cli,name:"workspace-ff",pid:100,status:nil,state:nil,waitingFor:nil)
  let discovery=ClaudeSessionDiscovery(home:root,listing:{[row]},desktopRoots:[desktop],coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[]))
  try event("user")
  let active=discovery.scan();check(active.count==1 && active[0].path==record.path && active[0].snapshot.state=="working","Desktop SDK without CLI activity fields must produce one active bubble")
  check(active[0].title=="桌面会话验收" && active[0].snapshot.messages.isEmpty,"Desktop title and privacy must survive discovery")
  check(LocalConversationProvider.claudeDesktopURL(record.path)?.absoluteString=="claude://claude.ai/epitaxy/local_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","Open the desktop conversation ID, not its CLI resume ID")
  check(LocalConversationProvider.resumeCommand(record.path)==nil,"Desktop navigation must not copy a CLI resume command")
  let coworkPath=root.appendingPathComponent("Claude-3p/local-agent-mode-sessions/account/org/"+local+".json").path
  check(LocalConversationProvider.claudeDesktopURL(coworkPath)?.absoluteString=="claude://claude.ai/cowork/local_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","Cowork navigation must open its own desktop route")
  check(LocalConversationProvider.label(coworkPath)=="Claude Cowork" && LocalConversationProvider.provider(coworkPath)=="claude","Cowork must retain its provider and visible source")
  try event("assistant","end_turn")
  check(discovery.scan().first?.snapshot.state=="completed","A completed Desktop turn must leave the active list")
  let initialIdle=ClaudeSessionDiscovery(home:root,listing:{[row]},desktopRoots:[desktop],coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[]));check(initialIdle.scan().isEmpty,"Warm idle SDK processes must never create initial bubbles")
  try event("user");check(discovery.scan().first?.snapshot.state=="working","Capture the next Desktop turn without adding a second session")
  try event("user",nil,"[Request interrupted by user for tool use]")
  check(discovery.scan().first?.snapshot.state=="cancelled","A stopped Desktop turn must leave the active list")
  let initialStopped=ClaudeSessionDiscovery(home:root,listing:{[row]},desktopRoots:[desktop],coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[]));check(initialStopped.scan().isEmpty,"A warm stopped SDK process must not create initial bubbles")
  try event("user");check(discovery.scan().first?.snapshot.state=="working","Recapture a Desktop session after Stop")
  var fallback="Claude Desktop 会话"
  let localizedIndex=ClaudeDesktopSessionIndex(roots:[desktop],untitled:{fallback})
  try metadata(title:"")
  check(localizedIndex.records()[cli]?.title==fallback,"An empty title uses the current language")
  fallback="Claude Desktop session"
  check(localizedIndex.records()[cli]?.title==fallback,"A cached empty title follows language changes without rewriting the source")
  try metadata(title:"Claude Desktop 会话")
  check(localizedIndex.records()[cli]?.title=="Claude Desktop 会话","A user title matching an old fallback must remain literal")
  var cliTitle:String?=nil
  var cliFallback="Claude Code 会话"
  let unnamed=ClaudeSessionDiscovery(home:root.appendingPathComponent("empty"),listing:{[ClaudeLiveSession(kind:"interactive",cwd:"/workspace",sessionId:cli,name:cliTitle,pid:100,status:"busy",state:nil,waitingFor:nil)]},desktopRoots:[],coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[]),untitled:{cliFallback})
  check(unnamed.scan().first?.title==cliFallback,"An unnamed live CLI uses the current fallback")
  cliFallback="Claude Code session"
  check(unnamed.scan().first?.title==cliFallback,"Generated CLI titles follow language changes")
  cliTitle="Claude Code 会话"
  check(unnamed.scan().first?.title==cliTitle,"Explicit CLI titles remain literal")
  cliTitle=nil
  check(unnamed.scan().first?.title=="Claude Code 会话","Retained source titles remain literal")
  try metadata(true);check(index.records().isEmpty && discovery.scan().isEmpty,"An archived Desktop conversation must not remain captured")
  check(LocalConversationProvider.claudeDesktopURL("/tmp/claude-code-sessions/local_invalid.json")==nil,"Malformed IDs must not reach desktop URL handling")
  print("Claude Desktop discovery, exact navigation, idle/active transitions and metadata privacy PASS")
 }
}
