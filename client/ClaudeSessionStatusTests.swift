import Foundation

@main struct ClaudeSessionStatusTests {
 final class Runner:AvatarProcessRunning {
  var invocation:AvatarProcessInvocation?
  var result=AvatarProcessResult(status:0,stdout:Data("[]".utf8),stderr:Data())
  func run(_ invocation:AvatarProcessInvocation)throws->AvatarProcessResult {self.invocation=invocation;return result}
 }
 static func main()throws {
  let data=Data(#"[{"kind":"interactive","cwd":"/qa/project","startedAt":1,"sessionId":"11111111-2222-3333-4444-555555555551","name":"修复登录","pid":100,"status":"busy"},{"kind":"interactive","cwd":"/qa/project","startedAt":2,"sessionId":"11111111-2222-3333-4444-555555555552","pid":101,"status":"waiting","waitingFor":"input needed"},{"kind":"background","cwd":"/qa/project","startedAt":3,"sessionId":"11111111-2222-3333-4444-555555555553","name":"完成的任务","pid":102,"status":"busy","state":"done"},{"kind":"interactive","cwd":"/qa/project","startedAt":4,"sessionId":"bad-id","pid":103,"status":"busy"}]"#.utf8)
  let sessions=try ClaudeSessionStatus.decode(data)
  precondition(sessions.count==3,"official UUIDs must be preserved and malformed identities rejected")
  precondition(sessions[0].activity=="working" && sessions[0].name=="修复登录","busy metadata preserves the real title")
  precondition(sessions[1].activity=="waiting_approval","waiting on user input stays visible without a Hook")
  precondition(sessions[2].activity=="completed","a terminal background state takes precedence over a stale busy flag")
  for bad in [Data("{}".utf8),Data(repeating:32,count:1_048_577)] {
   do {_ = try ClaudeSessionStatus.decode(bad);preconditionFailure("malformed or oversized listings must fail closed")}catch{}
  }
  let idle=try ClaudeSessionStatus.decode(Data(#"[{"kind":"interactive","cwd":"/qa","sessionId":"11111111-2222-3333-4444-555555555551","pid":100,"status":"idle"},{"kind":"background","cwd":"/qa","sessionId":"11111111-2222-3333-4444-555555555552","state":"working"}]"#.utf8))
  precondition(idle[0].activity=="idle" && idle[1].activity=="unknown","idle or missing live-process status is not executing")
  let runner=Runner()
  for future in [
   #"[{"kind":"interactive","cwd":"/qa","sessionId":"11111111-2222-3333-4444-555555555551","pid":100,"status":"future-running-state"}]"#,
   #"[{"kind":"futureKind","cwd":"/qa","sessionId":"11111111-2222-3333-4444-555555555551","pid":100,"status":"busy"}]"#,
   #"[{"kind":"background","cwd":"/qa","sessionId":"11111111-2222-3333-4444-555555555551","pid":100,"status":"busy","state":"futureState"}]"#
  ] {do {_ = try ClaudeSessionStatus.decode(Data(future.utf8));preconditionFailure("a changed activity contract cannot silently become a connected idle listing")}catch{}}
  _ = try ClaudeSessionStatus.query(environment:["CLAUDE_CONFIG_DIR":"/qa/config"],runner:runner,executable:"/qa/claude")
  precondition(runner.invocation?.arguments==["agents","--json"] && runner.invocation?.workingDirectory=="/" && runner.invocation?.environment["CLAUDE_CONFIG_DIR"]=="/qa/config","read-only official query must not enter a user project or include history")
  runner.result=AvatarProcessResult(status:1,stdout:Data("[]".utf8),stderr:Data("unsupported".utf8))
  do {_ = try ClaudeSessionStatus.query(runner:runner,executable:"/qa/claude");preconditionFailure("failed query cannot become a connected empty listing")}catch{}
  let cwd=try AvatarProcessRunner().run(.init(executable:"/bin/pwd",arguments:[],environment:[:],timeout:1,workingDirectory:"/"))
  precondition(cwd.status==0 && String(data:cwd.stdout,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines)=="/","process runner must apply safe query working directory")
  print("Claude official listing: busy / waiting / terminal precedence / identities / bounded malformed input PASS")
 }
}
