import Foundation
import Darwin

@main struct AvatarAgentAdaptersTests {
 final class FakeRunner:AvatarProcessRunning {
  var invocation:AvatarProcessInvocation?
  var result=AvatarProcessResult(status:0,stdout:Data(#"{"result":"{\"answer\":\"你好，访客\"}"}"#.utf8),stderr:Data())
  func run(_ invocation:AvatarProcessInvocation)throws->AvatarProcessResult{self.invocation=invocation;return result}
 }
 static func main()async throws{
  let runner=FakeRunner(),adapter=ClaudeAvatarAdapter(runner:runner,version:"2.1.235",executable:"/test-fixture/claude")
  let report=adapter.probe(help:"--bare --tools --disallowedTools --json-schema --no-session-persistence")
  assert(report.supported && report.isolationVerified)
  let answer=try adapter.answer(question:"只回答天气",timeout:3)
  assert(answer=="你好，访客")
  precondition(runner.invocation?.input==Data("只回答天气".utf8),"Claude question must use stdin")
  let args=runner.invocation?.arguments ?? []
  precondition(!args.contains("只回答天气"),"Claude question must not be visible in argv")
  assert(runner.invocation?.executable != "/usr/bin/env", "GUI launch must not rely on inherited PATH to find Claude")
  assert(runner.invocation?.executable.hasSuffix("/claude")==true)
  assert(args.contains("--bare"));assert(args.contains("--no-session-persistence"));assert(args.contains("--json-schema"));assert(args.contains("--tools"))
  if let i=args.firstIndex(of:"--tools"){assert(args.indices.contains(i+1)&&args[i+1].isEmpty)}else{fatalError("missing tools flag")}
  assert(!args.contains("--resume") && !args.contains("--continue") && !args.contains("--dangerously-skip-permissions"))
  assert(runner.invocation?.environment.keys.sorted()==["HOME","LANG","PATH","TMPDIR"])
  runner.result=AvatarProcessResult(status:1,stdout:Data(),stderr:Data("test failure".utf8))
  do{_ = try adapter.answer(question:"failure test",timeout:1);fatalError("nonzero exit accepted as answer")}catch AvatarAgentError.failed{}catch{fatalError("unexpected exit error: \(error)")}
  runner.result=AvatarProcessResult(status:0,stdout:Data("{}".utf8),stderr:Data())
  do{_ = try adapter.answer(question:"invalid response test",timeout:1);fatalError("missing answer accepted")}catch AvatarAgentError.invalidResponse{}catch{fatalError("unexpected parse error: \(error)")}
  do{_ = try AvatarProcessRunner().run(.init(executable:"/bin/sleep",arguments:["1"],environment:[:],timeout:0.05));fatalError("deadline not enforced")}catch AvatarAgentError.timedOut{}catch{fatalError("unexpected timeout error: \(error)")}
  let started=Date()
  let cancelled=Task.detached{try AvatarProcessRunner().run(.init(executable:"/bin/sleep",arguments:["2"],environment:[:],timeout:5))}
  try await Task.sleep(nanoseconds:50_000_000)
  cancelled.cancel()
  do{_ = try await cancelled.value;fatalError("cancelled Agent process continued running")}catch is CancellationError{}catch{fatalError("unexpected cancellation error: \(error)")}
  precondition(Date().timeIntervalSince(started)<1,"cancelled local process must exit promptly")
  let childRoot=FileManager.default.temporaryDirectory.appendingPathComponent("petlink-avatar-child-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:childRoot,withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:childRoot)}
  let pidFile=childRoot.appendingPathComponent("child-pid")
  let tree=Task.detached{try AvatarProcessRunner().run(.init(executable:"/bin/sh",arguments:["-c","trap '' TERM; /bin/sleep 30 & echo $! > \"$1\"; wait","avatar-cancel",pidFile.path],environment:[:],timeout:5))}
  while !FileManager.default.fileExists(atPath:pidFile.path){try await Task.sleep(nanoseconds:5_000_000)}
  let child=Int32(try String(contentsOf:pidFile,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines))!
  defer{if kill(child,0)==0{kill(child,SIGKILL)}}
  tree.cancel()
  do{_ = try await tree.value;fatalError("cancelled process tree returned success")}catch is CancellationError{}
  for _ in 0..<100 where kill(child,0)==0{try await Task.sleep(nanoseconds:10_000_000)}
  let survived=kill(child,0)==0
  if survived{kill(child,SIGKILL)}
  precondition(!survived,"Agent child survived cancellation")
  let leaderExited=Date()
  let drained=try AvatarProcessRunner().run(.init(executable:"/bin/sh",arguments:["-c","/bin/sleep 30 & echo leader-exited"],environment:[:],timeout:3))
  precondition(drained.status==0 && String(data:drained.stdout,encoding:.utf8)?.contains("leader-exited")==true && Date().timeIntervalSince(leaderExited)<1,"a child holding pipes must not block output after the leader exits")
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("petlink-resolver-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root.appendingPathComponent(".local/bin"),withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:root)}
  let candidate=root.appendingPathComponent(".local/bin/claude")
  try FileManager.default.copyItem(atPath:"/usr/bin/true",toPath:candidate.path)
  let resolved=try AgentExecutable.resolve("claude",environment:["PATH":"/usr/bin:/bin"],home:root.path)
  assert(resolved==candidate.path,"GUI environment cannot find local installation")
  let path=AgentExecutable.searchPath(environment:["PATH":".:relative:/tmp/../unsafe:/usr/bin"],home:root.path)
  assert(!path.split(separator:":").contains(".") && !path.contains("relative") && !path.contains(".."))

  let unsupported=CodexAvatarAdapter.installed(version:"0.154.0",restrictedReadProbePassed:false)
  assert(!unsupported.supported && !unsupported.isolationVerified)
  runner.result=AvatarProcessResult(status:0,stdout:Data(#"{"answer":"truncated"}"#.utf8),stderr:Data(),outputTruncated:true)
  do {_ = try adapter.answer(question:"truncated",timeout:3);fatalError("Claude truncation accepted")}catch AvatarAgentError.invalidResponse{}
  runner.result=AvatarProcessResult(status:0,stdout:try JSONSerialization.data(withJSONObject:["answer":String(repeating:"a",count:16385)]),stderr:Data())
  do {_ = try adapter.answer(question:"oversize answer",timeout:3);fatalError("Claude oversized answer accepted")}catch AvatarAgentError.invalidResponse{}
  // New providers must return a completed model answer and reject tool events.
  let codex=CodexAvatarAdapter(runner:runner,version:"0.160.0",executable:"/test-fixture/codex",model:"gpt-6.1-sol",features:["shell_tool","code_mode","plugins"])
  runner.result=AvatarProcessResult(status:0,stdout:Data("{\"type\":\"thread.started\",\"thread_id\":\"fixture\"}\n{\"type\":\"turn.started\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Codex answer\"}}\n{\"type\":\"turn.completed\"}\n".utf8),stderr:Data())
  let codexAnswer=try codex.answer(question:"private question",timeout:3);precondition(codexAnswer=="Codex answer")
  precondition(runner.invocation?.input==Data("private question".utf8))
  precondition(!(runner.invocation?.arguments.contains("private question") ?? true))
  precondition(!runner.invocation!.arguments.joined().contains("\\/"),"TOML paths must not contain JSON-only slash escapes")
  let directory=runner.invocation!.workingDirectory!
  precondition(!FileManager.default.fileExists(atPath:directory),"temporary context must be removed")
  runner.result=AvatarProcessResult(status:0,stdout:Data("{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\"}}\n{\"type\":\"turn.completed\"}\n".utf8),stderr:Data())
  do {_ = try codex.answer(question:"read file",timeout:3);fatalError("tool execution accepted")}catch AvatarAgentError.invalidResponse{}
  let dsh=DSHAvatarAdapter(runner:runner,version:"0.2.0-rc.2",executable:"/fixture/DeepSeek Harness",script:"/fixture/DSHAvatarRuntime.mjs",runtimeRoot:"/fixture/runtime")
  runner.result=AvatarProcessResult(status:0,stdout:Data(#"{"answer":"DSH answer","tools":0,"messages":2}"#.utf8),stderr:Data())
  let dshAnswer=try dsh.answer(question:"DSH private question",timeout:3);precondition(dshAnswer=="DSH answer")
  precondition(!(runner.invocation?.arguments.contains("DSH private question") ?? true))
  precondition(!FileManager.default.fileExists(atPath:runner.invocation!.workingDirectory!))
  runner.result=AvatarProcessResult(status:0,stdout:Data(#"{"answer":"unsafe","tools":1,"messages":2}"#.utf8),stderr:Data())
  do {_ = try dsh.answer(question:"read file",timeout:3);fatalError("DSH tools accepted")}catch AvatarAgentError.invalidResponse{}
  do {_ = try DSHAvatarAdapter(runner:runner,version:"0.2.1",executable:"/fixture/dsh",script:"/fixture/runtime.mjs",runtimeRoot:"/fixture").answer(question:"future",timeout:3);fatalError("unknown DSH contract accepted")}catch AvatarAgentError.unsupported{}
  var discovery=AvatarProviderRefresh()
  precondition(discovery.begin(epoch:1,authorized:true))
  precondition(!discovery.begin(epoch:1,authorized:true))
  precondition(discovery.begin(epoch:2,authorized:true),"a newly authorized account must not be blocked by an old check")
  precondition(!discovery.finish(epoch:1,currentEpoch:2) && discovery.isChecking,"old completion must preserve the new probe")
  precondition(discovery.finish(epoch:2,currentEpoch:2) && !discovery.isChecking)
  precondition(discovery.begin(epoch:3,authorized:true))
  precondition(discovery.begin(epoch:4,authorized:true))
  precondition(discovery.finish(epoch:4,currentEpoch:4))
  precondition(!discovery.finish(epoch:3,currentEpoch:4) && !discovery.isChecking)
  precondition(!discovery.begin(epoch:5,authorized:false),"no discovery before avatar authorization")
  runner.result=AvatarProcessResult(status:0,stdout:Data(#"{"answer":"bounded","tools":0,"messages":2}"#.utf8),stderr:Data())
  _ = try dsh.answer(question:String(repeating:"a",count:8192),timeout:3)
  do {_ = try dsh.answer(question:String(repeating:"a",count:8193),timeout:3);fatalError("oversize question accepted")}catch AvatarAgentError.invalidResponse{}
  let inputResult=try AvatarProcessRunner().run(.init(executable:"/bin/cat",arguments:[],environment:[:],timeout:3,input:Data("private stdin test".utf8)))
  precondition(String(data:inputResult.stdout,encoding:.utf8)=="private stdin test")
  let largeOutput=try AvatarProcessRunner().run(.init(executable:"/bin/sh",arguments:["-c","/usr/bin/yes fixture | /usr/bin/head -c 1100000"],environment:[:],timeout:3))
  precondition(largeOutput.outputTruncated && largeOutput.stdout.count==1<<20)
  runner.result=AvatarProcessResult(status:0,stdout:Data(#"{"answer":"truncated","tools":0,"messages":2}"#.utf8),stderr:Data(),outputTruncated:true)
  do {_ = try dsh.answer(question:"truncated",timeout:3);fatalError("truncated output accepted")}catch AvatarAgentError.invalidResponse{}
  do {_ = try CodexAvatarAdapter(runner:runner,version:"0.161.0",executable:"/fixture/codex",model:"fixture",features:["shell_tool"]).answer(question:"future",timeout:3);fatalError("unknown Codex contract accepted")}catch AvatarAgentError.unsupported{}
  print("Avatar adapters: three providers / private stdin / cancellation / protocol and output rejection PASS")
 }
}
