import Foundation
@main struct ClaudeConversationTests {
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let project=root.appendingPathComponent("projects/project");try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
  let file=project.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl")
  func row(_ type:String,_ content:Any,_ stop:String?=nil)->[String:Any]{var message:[String:Any]=["content":content];if let stop{message["stop_reason"]=stop};return ["type":type,"timestamp":ISO8601DateFormatter().string(from:Date()),"uuid":UUID().uuidString,"message":message]}
  func write(_ rows:[[String:Any]],append:Bool=false)throws {let data=try rows.reduce(into:Data()){out,row in out.append(try JSONSerialization.data(withJSONObject:row));out.append(10)};if append{let h=try FileHandle(forWritingTo:file);try h.seekToEnd();try h.write(contentsOf:data);try h.close()}else{try data.write(to:file)}}
  try write([row("user","Fix the pet menu"),row("assistant",[["type":"thinking","thinking":"private"]]),row("assistant",[["type":"tool_use","name":"Bash"]],"tool_use")])
  let reader=ClaudeConversationReader();let active=try reader.poll(file)
  precondition(active.state=="working" && active.messages.count==1)
  precondition(reader.title=="Fix the pet menu")
  var live=ClaudeLiveSession(kind:"interactive",cwd:"/project",sessionId:"11111111-2222-3333-4444-555555555555",name:nil,pid:100,status:"busy",state:nil,waitingFor:nil)
  let discovery=ClaudeSessionDiscovery(home:root,listing:{[live]},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[]));precondition(discovery.scan().count==1)
  live=ClaudeLiveSession(kind:"interactive",cwd:"/qa/petlink.LiveCase",sessionId:live.sessionId,name:"petlink-livecase-7d",pid:100,status:"busy",state:nil,waitingFor:nil)
  precondition(discovery.scan().first?.title=="Fix the pet menu","a slugged directory name with a generated suffix must not overwrite the conversation title")
  live=ClaudeLiveSession(kind:"interactive",cwd:"/qa/petlink.LiveCase",sessionId:live.sessionId,name:"My pet menu review",pid:100,status:"busy",state:nil,waitingFor:nil)
  precondition(discovery.scan().first?.title=="My pet menu review","a user-provided official name takes precedence")
  try write([row("user",[["type":"tool_result","content":"secret"]]),row("assistant",[["type":"text","text":"Menu ready"]],"end_turn")],append:true)
  let done=try reader.poll(file);precondition(done.state=="completed" && done.messages.count==2 && done.progress=="Menu ready" && done.completionID != nil)
  precondition(discovery.scan().first?.snapshot.state=="working","transcript completion must not override official busy status")
  live=ClaudeLiveSession(kind:"interactive",cwd:"/project",sessionId:live.sessionId,name:nil,pid:100,status:"idle",state:nil,waitingFor:nil)
  precondition(discovery.scan().first?.snapshot.state=="completed","official idle retires an observed active turn")
  let clean=ClaudeSessionDiscovery(home:root,listing:{[live]},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[]));precondition(clean.scan().isEmpty,"initial idle sessions must not capture")
  try write([["type":"custom-title","customTitle":"Hand drawn pet menu"]],append:true);_ = try reader.poll(file);precondition(reader.title=="Hand drawn pet menu")
  try write([row("user","New turn")]);let renewed=try reader.poll(file);precondition(renewed.state=="working")
  try write([row("assistant",[["type":"text","text":"sidechain"]],"end_turn").merging(["isSidechain":true]){$1}],append:true)
  let side=try reader.poll(file);precondition(side.state=="working")
  print("Claude transcript: activity, titles, completion, privacy and truncate PASS")
 }
}
