import Foundation

struct ClaudeLiveSession:Decodable {
 let kind:String
 let cwd:String
 let sessionId:String?
 let name:String?
 let pid:Int?
 let status:String?
 let state:String?
 let waitingFor:String?
 var activity:String {
  guard ["interactive","background"].contains(kind) else{return "unknown"}
  if kind=="background" {
   if state=="done" {return "completed"}
   if state=="failed" {return "failed"}
   if state=="stopped" {return "cancelled"}
   guard ["working","blocked"].contains(state ?? "") else{return "unknown"}
  }
  guard (pid ?? 0)>0 else{return "unknown"}
  switch status {case "busy":return "working";case "waiting":return "waiting_approval";case "idle":return "idle";default:return "unknown"}
 }
}
enum ClaudeSessionStatus {
 static func decode(_ data:Data)throws->[ClaudeLiveSession] {
  guard data.count<=1_048_576 else{throw CocoaError(.fileReadTooLarge)}
  let rows=try JSONDecoder().decode([ClaudeLiveSession].self,from:data)
  guard rows.count<=4096 else{throw CocoaError(.fileReadTooLarge)}
  let valid=rows.filter{UUID(uuidString:$0.sessionId ?? "") != nil}
  guard valid.allSatisfy({row in
   ["interactive","background"].contains(row.kind) &&
   (row.status.map{["busy","waiting","idle"].contains($0)} ?? true) &&
   (row.kind != "background" || row.state.map{["working","blocked","done","failed","stopped"].contains($0)} ?? true)
  }) else{throw AvatarAgentError.invalidResponse}
  return valid
 }
 static func query(environment:[String:String]=ProcessInfo.processInfo.environment,runner:AvatarProcessRunning=AvatarProcessRunner(),executable:String?=nil)throws->[ClaudeLiveSession] {
  let executable=try executable ?? AgentExecutable.resolve("claude",environment:environment)
  var env=environment;env["PATH"]=AgentExecutable.searchPath(environment:environment)
  let result=try runner.run(AvatarProcessInvocation(executable:executable,arguments:["agents","--json"],environment:env,timeout:4,workingDirectory:"/"))
  guard result.status==0 else{throw AvatarAgentError.failed(L10n.text("Claude Code 状态查询失败，请重试。"))}
  do{return try decode(result.stdout)}catch{throw AvatarAgentError.invalidResponse}
 }
}
