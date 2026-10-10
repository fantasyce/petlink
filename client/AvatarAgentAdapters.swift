import Foundation
import Darwin

enum AgentExecutable {
 static func searchPath(environment:[String:String]=ProcessInfo.processInfo.environment,home:String=FileManager.default.homeDirectoryForCurrentUser.path)->String {
  // LaunchServices does not inherit interactive shell startup files. Never
  // source them or search the working directory to locate an Agent executable.
  let known=[home+"/.local/bin","/opt/homebrew/bin","/usr/local/bin","/usr/bin","/bin","/usr/sbin","/sbin"]
  let inherited=(environment["PATH"] ?? "").split(separator:":").map(String.init).filter{$0.hasPrefix("/") && !$0.split(separator:"/").contains("..")}
  var seen=Set<String>()
  return (known+inherited).filter{seen.insert($0).inserted}.joined(separator:":")
 }
 static func resolve(_ name:String,environment:[String:String]=ProcessInfo.processInfo.environment,home:String=FileManager.default.homeDirectoryForCurrentUser.path)throws->String {
  guard ["claude","codex"].contains(name) else{throw AvatarAgentError.unsupported(L10n.text("未知 Agent"))}
  for directory in searchPath(environment:environment,home:home).split(separator:":") {
   let path=String(directory)+"/"+name
   var isDirectory:ObjCBool=false
   if FileManager.default.fileExists(atPath:path,isDirectory:&isDirectory),!isDirectory.boolValue,FileManager.default.isExecutableFile(atPath:path){
    // Discovering a version must not launch a quarantined file before macOS
    // permits it. Assessment is read-only and never approves or clears flags.
    if getxattr(path,"com.apple.quarantine",nil,0,0,0)>0 {
     let assessment=try? AvatarProcessRunner().run(.init(executable:"/usr/sbin/spctl",arguments:["--assess","--type","execute",path],environment:[:],timeout:4,workingDirectory:"/"))
     guard assessment?.status==0 else{continue}
    }
    return path
   }
  }
  throw AvatarAgentError.unsupported(L10n.text("未找到 {0}，请检查本机 Agent 安装", name))
 }
}

struct AvatarProcessInvocation {
 let executable:String
 let arguments:[String]
 let environment:[String:String]
 let timeout:TimeInterval
 var workingDirectory:String?=nil
 var input:Data?=nil
}

struct AvatarProcessResult {
 let status:Int32
 let stdout:Data
 let stderr:Data
 var outputTruncated:Bool=false
}

protocol AvatarProcessRunning {
 func run(_ invocation:AvatarProcessInvocation)throws->AvatarProcessResult
}

enum AvatarAgentError:LocalizedError {
 case unsupported(String),timedOut,failed(String),invalidResponse
 var errorDescription:String? {
  switch self {
  case .unsupported(let reason):return reason
  case .timedOut:return L10n.text("本地 Agent 响应超时")
  case .failed(let message):return message
  case .invalidResponse:return L10n.text("本地 Agent 返回了无法识别的结果")
  }
 }
}

private final class AvatarOutputBuffer {
 private let lock=NSLock()
 private var data=Data()
 private var truncated=false
 func drain(_ handle:FileHandle){
  while let chunk=try? handle.read(upToCount:8192),!chunk.isEmpty{
   lock.lock();let remaining=max(0,(1<<20)-data.count);truncated = truncated || chunk.count>remaining;data.append(chunk.prefix(remaining));lock.unlock()
  }
 }
 func value()->Data{lock.lock();defer{lock.unlock()};return data}
 func wasTruncated()->Bool{lock.lock();defer{lock.unlock()};return truncated}
}

private func withAvatarCStringArray<T>(_ values:[String],_ body:(UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>)throws->T)rethrows->T {
 var pointers=values.map{strdup($0)}+[nil]
 defer{for pointer in pointers{free(pointer)}}
 return try pointers.withUnsafeMutableBufferPointer{try body($0.baseAddress!)}
}

struct AvatarProcessRunner:AvatarProcessRunning {
 func run(_ invocation:AvatarProcessInvocation)throws->AvatarProcessResult {
  try Task.checkCancellation()
  let stdout=Pipe(),stderr=Pipe()
  let output=AvatarOutputBuffer(),errors=AvatarOutputBuffer()
  var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?,pid:pid_t=0
  func checked(_ result:Int32)throws{if result != 0{throw NSError(domain:NSPOSIXErrorDomain,code:Int(result))}}
  try checked(posix_spawn_file_actions_init(&actions))
  defer{posix_spawn_file_actions_destroy(&actions)}
  if let directory=invocation.workingDirectory {
   if #available(macOS 26.0,*) {try checked(posix_spawn_file_actions_addchdir(&actions,directory))}
   else {try checked(posix_spawn_file_actions_addchdir_np(&actions,directory))}
  }
  try checked(posix_spawnattr_init(&attributes))
  defer{posix_spawnattr_destroy(&attributes)}
  // A dedicated process group keeps cancellation limited to this invocation,
  // including descendants which still hold output pipes after the leader exits.
  try checked(posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP)))
  try checked(posix_spawnattr_setpgroup(&attributes,0))
  guard (invocation.input?.count ?? 0)<=65_536 else{throw AvatarAgentError.invalidResponse}
  let inputPipe=invocation.input == nil ? nil:Pipe()
  let input=inputPipe?.fileHandleForReading.fileDescriptor ?? open("/dev/null",O_RDONLY)
  guard input>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
  defer{if inputPipe==nil{close(input)}}
  if let pipe=inputPipe{try checked(posix_spawn_file_actions_addclose(&actions,pipe.fileHandleForWriting.fileDescriptor));_ = fcntl(pipe.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)}
  try checked(posix_spawn_file_actions_adddup2(&actions,input,STDIN_FILENO))
  try checked(posix_spawn_file_actions_adddup2(&actions,stdout.fileHandleForWriting.fileDescriptor,STDOUT_FILENO))
  try checked(posix_spawn_file_actions_adddup2(&actions,stderr.fileHandleForWriting.fileDescriptor,STDERR_FILENO))
  for fd in [input,stdout.fileHandleForReading.fileDescriptor,stderr.fileHandleForReading.fileDescriptor,stdout.fileHandleForWriting.fileDescriptor,stderr.fileHandleForWriting.fileDescriptor]{try checked(posix_spawn_file_actions_addclose(&actions,fd))}
  let environment=invocation.environment.sorted{$0.key<$1.key}.map{"\($0.key)=\($0.value)"}
  let spawned=withAvatarCStringArray([invocation.executable]+invocation.arguments){argv in
   withAvatarCStringArray(environment){env in
    invocation.executable.withCString{posix_spawn(&pid,$0,&actions,&attributes,argv,env)}
   }
  }
  guard spawned==0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(spawned))}
  if let pipe=inputPipe,let bytes=invocation.input {
   try pipe.fileHandleForReading.close()
   DispatchQueue.global().async{try? pipe.fileHandleForWriting.write(contentsOf:bytes);try? pipe.fileHandleForWriting.close()}
  }
  try stdout.fileHandleForWriting.close();try stderr.fileHandleForWriting.close()
  let drains=DispatchGroup()
  drains.enter();DispatchQueue.global().async{output.drain(stdout.fileHandleForReading);drains.leave()}
  drains.enter();DispatchQueue.global().async{errors.drain(stderr.fileHandleForReading);drains.leave()}
  let deadline=Date().addingTimeInterval(invocation.timeout)
  var timedOut=false,waitError:Int32=0
  while true {
   var information=siginfo_t()
   // Do not reap the leader until its group has been terminated: retaining the
   // PID prevents another process from reusing the group identifier meanwhile.
   let checked=waitid(P_PID,id_t(pid),&information,WEXITED|WNOHANG|WNOWAIT)
   if checked<0 && errno != EINTR{waitError=errno;break}
   if information.si_pid==pid{break}
   if Task.isCancelled{break}
   if Date()>=deadline{timedOut=true;break}
   Thread.sleep(forTimeInterval:0.02)
  }
  kill(-pid,SIGTERM)
  Thread.sleep(forTimeInterval:0.1)
  kill(-pid,SIGKILL)
  var status:Int32=0
  while waitpid(pid,&status,0)<0 && errno==EINTR{}
  guard drains.wait(timeout:.now()+2) == .success else{throw AvatarAgentError.timedOut}
  try Task.checkCancellation()
  if waitError != 0{throw NSError(domain:NSPOSIXErrorDomain,code:Int(waitError))}
  if timedOut{throw AvatarAgentError.timedOut}
  let exitStatus=(status & 0x7f)==0 ? (status>>8)&0xff:128+(status & 0x7f)
  return AvatarProcessResult(status:exitStatus,stdout:output.value(),stderr:errors.value(),outputTruncated:output.wasTruncated() || errors.wasTruncated())
 }
}

struct AvatarCapabilityReport:Equatable {
 let supported:Bool
 let isolationVerified:Bool
 let reason:String
}

struct ClaudeAvatarAdapter {
 private let runner:AvatarProcessRunning
 private let executable:String?
 let version:String
 init(runner:AvatarProcessRunning=AvatarProcessRunner(),version:String,executable:String?=nil){self.runner=runner;self.version=version;self.executable=executable}

 func probe(help:String)->AvatarCapabilityReport {
  let required=["--bare","--tools","--json-schema","--no-session-persistence"]
  let missing=required.filter{!help.contains($0)}
  return missing.isEmpty
   ? .init(supported:true,isolationVerified:true,reason:L10n.text("Claude Code {0} 无工具、无会话持久化模式可用", version))
   : .init(supported:false,isolationVerified:false,reason:L10n.text("缺少安全隔离参数：{0}", missing.joined(separator:", ")))
 }

 func answer(question:String,timeout:TimeInterval)throws->String {
  guard !question.isEmpty,question.utf8.count<=8_192 else{throw AvatarAgentError.invalidResponse}
  let context=try AvatarInvocationContext();defer{context.remove()}
  let schema=#"{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}"#
  let args=["--bare","-p","--tools","","--disable-slash-commands","--no-session-persistence","--output-format","json","--json-schema",schema,"--max-turns","2","--permission-mode","dontAsk","--system-prompt","你是来访桌宠的只读问答分身。只能依据模型自身知识回答；不能使用工具、文件、终端、网络、会话历史或用户环境。若问题要求这些能力，请明确拒绝。输出符合给定 JSON schema。"]
  let current=ProcessInfo.processInfo.environment
  var environment:[String:String]=[:]
  for key in ["HOME","LANG","PATH","TMPDIR"] {if let value=current[key]{environment[key]=value}}
  environment["PATH"]=AgentExecutable.searchPath()
  let result=try runner.run(.init(executable:try executable ?? AgentExecutable.resolve("claude"),arguments:args,environment:environment,timeout:timeout,workingDirectory:context.root.path,input:Data(question.utf8)))
  guard result.status==0 else{throw AvatarAgentError.failed(L10n.text("Claude Code 回答失败，请检查登录与额度"))}
  guard !result.outputTruncated else{throw AvatarAgentError.invalidResponse}
  return try checkedAvatarAnswer(Self.parseAnswer(result.stdout))
 }

 func answerAsync(question:String,timeout:TimeInterval)async throws->String {
  let worker=Task.detached{try Task.checkCancellation();return try answer(question:question,timeout:timeout)}
  return try await withTaskCancellationHandler(operation:{let answer=try await worker.value;try Task.checkCancellation();return answer},onCancel:{worker.cancel()})
 }

 private static func parseAnswer(_ data:Data)throws->String {
  guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw AvatarAgentError.invalidResponse}
  if let output=object["structured_output"] as? [String:Any],let answer=output["answer"] as? String,!answer.isEmpty{return answer}
  if let answer=object["answer"] as? String,!answer.isEmpty{return answer}
  if let result=object["result"] as? String,
     let nested=result.data(using:.utf8),
     let output=try? JSONSerialization.jsonObject(with:nested) as? [String:Any],
     let answer=output["answer"] as? String,!answer.isEmpty{return answer}
  throw AvatarAgentError.invalidResponse
 }
}

// Each invocation owns an empty, private context. It never copies credentials,
// project instructions, transcripts or the question into files.
private struct AvatarInvocationContext {
 let root:URL
 init()throws {
  root=FileManager.default.temporaryDirectory.appendingPathComponent("petlink-avatar-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
 }
 func remove(){try? FileManager.default.removeItem(at:root)}
 func write(_ data:Data,name:String)throws->URL {
  let file=root.appendingPathComponent(name);try data.write(to:file,options:.atomic)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);return file
 }
}

private let avatarKnowledgeInstructions="You answer questions from a visiting pet using model knowledge only. No tools, files, commands, web access, user instructions, or conversation history are available. Refuse requests requiring those resources. Answer concisely in the user's language."

private func avatarEnvironment(home:String?=nil)->[String:String] {
 let current=ProcessInfo.processInfo.environment
 var result:[String:String]=[:]
 for key in ["HOME","LANG","TMPDIR","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY","http_proxy","https_proxy","all_proxy","no_proxy"]{if let value=current[key]{result[key]=value}}
 result["PATH"]=AgentExecutable.searchPath()
 if let home{result["HOME"]=home}
 return result
}

private func checkedAvatarAnswer(_ answer:String)throws->String {
 guard !answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,answer.utf8.count<=16_384 else{throw AvatarAgentError.invalidResponse};return answer
}

struct CodexAvatarAdapter {
 let runner:AvatarProcessRunning
 let version:String
 let executable:String
 let model:String
 let features:[String]
 init(runner:AvatarProcessRunning=AvatarProcessRunner(),version:String,executable:String,model:String,features:[String]){self.runner=runner;self.version=version;self.executable=executable;self.model=model;self.features=features}
 static func installed(version:String,restrictedReadProbePassed:Bool)->AvatarCapabilityReport {
  let supported=version=="0.160.0" && restrictedReadProbePassed
  return .init(supported:supported,isolationVerified:supported,reason:supported ? L10n.text("模型知识问答可用"):L10n.text("当前 Codex 版本尚未完成数字分身兼容验证"))
 }
 func answer(question:String,timeout:TimeInterval)throws->String {
  guard version=="0.160.0" else{throw AvatarAgentError.unsupported(L10n.text("当前 Codex 版本尚未完成数字分身兼容验证"))}
  guard !question.isEmpty,question.utf8.count<=8_192,!model.isEmpty,model.utf8.count<=100,!features.isEmpty,features.allSatisfy({$0.range(of:"^[a-z0-9_]+$",options:.regularExpression) != nil}) else{throw AvatarAgentError.invalidResponse}
  let context=try AvatarInvocationContext();defer{context.remove()}
  let catalog:[String:Any]=["models":[["slug":model,"display_name":model,"description":NSNull(),"supported_reasoning_levels":[],"shell_type":"disabled","visibility":"list","supported_in_api":true,"priority":0,"availability_nux":NSNull(),"upgrade":NSNull(),"support_verbosity":false,"default_verbosity":NSNull(),"apply_patch_tool_type":NSNull(),"truncation_policy":["mode":"bytes","limit":10000],"experimental_supported_tools":[],"include_skills_usage_instructions":false,"include_plugin_usage_instructions":false,"include_apps_usage_instructions":false,"model_messages":["instructions_template":avatarKnowledgeInstructions,"instructions_variables":NSNull()]]]]
  let catalogURL=try context.write(JSONSerialization.data(withJSONObject:catalog),name:"models.json")
  let instructions=try context.write(Data(avatarKnowledgeInstructions.utf8),name:"instructions.txt")
  func tomlString(_ value:String)throws->String{String(data:try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.withoutEscapingSlashes]),encoding:.utf8)!}
  var args=["exec","--ignore-user-config","--ignore-rules","--strict-config","--ephemeral","--json","--skip-git-repo-check","-s","read-only","-C",context.root.path]
  for feature in features{args += ["-c","features."+feature+"=false"]}
  let settings=["features.skip_host_skill_discovery=true","suppress_unstable_features_warning=true","web_search=\"disabled\"","project_doc_max_bytes=0","skills.include_instructions=false","tools.update_plan.enabled=false","tools.experimental_request_user_input.enabled=false","model="+(try tomlString(model)),"model_reasoning_effort=\"low\"","model_catalog_json="+(try tomlString(catalogURL.path)),"model_instructions_file="+(try tomlString(instructions.path))]
  for setting in settings{args += ["-c",setting]};args.append("-")
  var environment=avatarEnvironment(home:context.root.path)
  environment["CODEX_HOME"]=ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
  let result=try runner.run(.init(executable:executable,arguments:args,environment:environment,timeout:timeout,workingDirectory:context.root.path,input:Data(question.utf8)))
  guard result.status==0 else{throw AvatarAgentError.failed(L10n.text("Codex 回答失败，请检查 Codex 登录与额度"))}
  guard !result.outputTruncated,let output=String(data:result.stdout,encoding:.utf8) else{throw AvatarAgentError.invalidResponse}
  var answer:String?,started=false,completed=false,thread=false
  for line in output.split(separator:"\n") {
   guard let event=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],let type=event["type"] as? String,!completed else{throw AvatarAgentError.invalidResponse}
   switch type {
   case "thread.started":guard !thread,!started else{throw AvatarAgentError.invalidResponse};thread=true
   case "turn.started":guard thread,!started else{throw AvatarAgentError.invalidResponse};started=true
   case "item.started","item.updated","item.completed":
    guard started,let item=event["item"] as? [String:Any],let kind=item["type"] as? String,["agent_message","reasoning"].contains(kind) else{throw AvatarAgentError.invalidResponse}
    if type=="item.completed",kind=="agent_message"{guard answer==nil,let text=item["text"] as? String else{throw AvatarAgentError.invalidResponse};answer=text}
   case "turn.completed":guard started,answer != nil else{throw AvatarAgentError.invalidResponse};completed=true
   case "error","turn.failed":throw AvatarAgentError.failed(L10n.text("Codex 未完成回答，请检查登录与额度"))
   default:throw AvatarAgentError.invalidResponse
   }
  }
  guard completed,let answer else{throw AvatarAgentError.invalidResponse};return try checkedAvatarAnswer(answer)
 }
}

struct DSHAvatarAdapter {
 let runner:AvatarProcessRunning
 let version:String
 let executable:String
 let script:String
 let runtimeRoot:String
 init(runner:AvatarProcessRunning=AvatarProcessRunner(),version:String,executable:String,script:String,runtimeRoot:String){self.runner=runner;self.version=version;self.executable=executable;self.script=script;self.runtimeRoot=runtimeRoot}
 func answer(question:String,timeout:TimeInterval)throws->String {
  guard version=="0.2.0-rc.2" else{throw AvatarAgentError.unsupported(L10n.text("当前 DeepSeek Harness 版本尚未完成数字分身兼容验证"))}
  guard !question.isEmpty,question.utf8.count<=8_192 else{throw AvatarAgentError.invalidResponse}
  let context=try AvatarInvocationContext();defer{context.remove()}
  var environment=avatarEnvironment();environment["ELECTRON_RUN_AS_NODE"]="1"
  environment["DSH_HOME"]=ProcessInfo.processInfo.environment["DSH_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh").path
  let input=try JSONSerialization.data(withJSONObject:["question":question,"timeout_ms":Int(timeout*1000)])
  let result=try runner.run(.init(executable:executable,arguments:[script,runtimeRoot],environment:environment,timeout:timeout,workingDirectory:context.root.path,input:input))
  guard result.status==0 else{throw AvatarAgentError.failed(L10n.text("DeepSeek Harness 回答失败，请检查桌面版的模型登录与额度"))}
  guard !result.outputTruncated,let object=try JSONSerialization.jsonObject(with:result.stdout) as? [String:Any],object["tools"] as? Int==0,object["messages"] as? Int==2,object["error"]==nil,let answer=object["answer"] as? String else{throw AvatarAgentError.invalidResponse}
  return try checkedAvatarAnswer(answer)
 }
 static func installation(scriptOverride:String?=nil)throws->DSHAvatarAdapter {
  let homes=[URL(fileURLWithPath:"/Applications"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
  for home in homes {
   let app=home.appendingPathComponent("DeepSeek Harness.app")
   guard let bundle=Bundle(url:app),bundle.bundleIdentifier=="com.deepseek.dsh",let executable=bundle.executableURL,let version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String else{continue}
   guard let script=scriptOverride ?? Bundle.main.url(forResource:"DSHAvatarRuntime",withExtension:"mjs")?.path else{throw AvatarAgentError.unsupported(L10n.text("数字分身运行资源缺失，请重新安装 PetLink"))}
   return .init(version:version,executable:executable.path,script:script,runtimeRoot:app.appendingPathComponent("Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai").path)
  }
  throw AvatarAgentError.unsupported(L10n.text("请先安装 DeepSeek Harness 桌面版"))
 }
}

enum AvatarAnswerRuntime {
 static let providers=["claude","codex","deepseek"]
 static func codexAdapter()throws->CodexAvatarAdapter {
  let runner=AvatarProcessRunner(),path=try AgentExecutable.resolve("codex"),env=avatarEnvironment()
  let versionResult=try runner.run(.init(executable:path,arguments:["--version"],environment:env,timeout:5))
  guard versionResult.status==0,let versionText=String(data:versionResult.stdout,encoding:.utf8),versionText.trimmingCharacters(in:.whitespacesAndNewlines)=="codex-cli 0.160.0" else{throw AvatarAgentError.unsupported(L10n.text("当前 Codex 版本尚未完成数字分身兼容验证"))}
  let featureResult=try runner.run(.init(executable:path,arguments:["features","list"],environment:env,timeout:5))
  guard featureResult.status==0,!featureResult.outputTruncated,let featureText=String(data:featureResult.stdout,encoding:.utf8) else{throw AvatarAgentError.invalidResponse}
  let features=featureText.split(separator:"\n").filter{!$0.contains("removed") && !$0.contains("deprecated")}.compactMap{$0.split(whereSeparator:{$0.isWhitespace}).first.map(String.init)}
  guard Set(["shell_tool","plugins","apps","multi_agent","hooks","code_mode","view_image","skip_host_skill_discovery"]).isSubset(of:Set(features)) else{throw AvatarAgentError.unsupported(L10n.text("Codex 安全隔离参数已变化，请更新 PetLink"))}
  let home=ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
  let cache=URL(fileURLWithPath:home).appendingPathComponent("models_cache.json")
  guard let size=try? cache.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<2_000_000,let data=try? Data(contentsOf:cache),let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let models=json["models"] as? [[String:Any]],let model=models.first(where:{$0["visibility"] as? String=="list" && $0["slug"] as? String != "codex-auto-review"})?["slug"] as? String else{throw AvatarAgentError.unsupported(L10n.text("请先在 Codex 中登录并打开一次对话"))}
  return .init(version:"0.160.0",executable:path,model:model,features:features)
 }
 static func availability(_ provider:String)->AvatarCapabilityReport {
  do {
   switch provider {
   case "codex":_ = try codexAdapter()
   case "deepseek":let adapter=try DSHAvatarAdapter.installation();guard adapter.version=="0.2.0-rc.2" else{throw AvatarAgentError.unsupported(L10n.text("当前 DeepSeek Harness 版本尚未完成数字分身兼容验证"))}
   case "claude":let path=try AgentExecutable.resolve("claude");let help=try AvatarProcessRunner().run(.init(executable:path,arguments:["--help"],environment:avatarEnvironment(),timeout:5));guard help.status==0,ClaudeAvatarAdapter(version:"installed").probe(help:String(data:help.stdout,encoding:.utf8) ?? "").supported else{throw AvatarAgentError.unsupported(L10n.text("当前 Claude Code 缺少数字分身隔离参数"))}
   default:throw AvatarAgentError.unsupported(L10n.text("未知的回答 Agent"))
   }
   return .init(supported:true,isolationVerified:true,reason:L10n.text("可用于数字分身回答"))
  }catch{return .init(supported:false,isolationVerified:false,reason:error.localizedDescription)}
 }
 static func answerAsync(provider:String,question:String,timeout:TimeInterval)async throws->String {
  let worker=Task.detached{()->String in
   try Task.checkCancellation()
   switch provider {
   case "codex":return try codexAdapter().answer(question:question,timeout:timeout)
   case "deepseek":return try DSHAvatarAdapter.installation().answer(question:question,timeout:timeout)
   case "claude":return try ClaudeAvatarAdapter(version:"installed").answer(question:question,timeout:timeout)
   default:throw AvatarAgentError.unsupported(L10n.text("未知的回答 Agent"))
   }
  }
  return try await withTaskCancellationHandler(operation:{let result=try await worker.value;try Task.checkCancellation();return result},onCancel:{worker.cancel()})
 }
}

// A new account starts its own discovery immediately. An old completion may
// neither publish another account's results nor clear the current progress.
struct AvatarProviderRefresh {
 private var activeEpoch:Int?
 var isChecking:Bool{activeEpoch != nil}
 mutating func begin(epoch:Int,authorized:Bool)->Bool {
  guard authorized,activeEpoch != epoch else{return false};activeEpoch=epoch;return true
 }
 mutating func finish(epoch:Int,currentEpoch:Int)->Bool {
  guard activeEpoch==epoch else{return false};activeEpoch=nil;return epoch==currentEpoch
 }
}
