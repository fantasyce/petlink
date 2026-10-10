import Foundation

struct AgentInstalledVersion:Equatable {
 let version:String
 let issue:String
}

// Confined to the coordinator's version-discovery queue.
final class AgentVersionMonitor: @unchecked Sendable {
 private let resolve:(String)->String?
 private let runner:AvatarProcessRunning
 private let desktopApplication:()->URL?
 private struct Fingerprint:Equatable {let path:String;let inode:UInt64;let size:UInt64;let modified:Date}
 private var cached:[String:(Fingerprint,AgentInstalledVersion)]=[:]
 init(resolve:@escaping(String)->String?={try? AgentExecutable.resolve($0)},runner:AvatarProcessRunning=AvatarProcessRunner(),desktopApplication:@escaping()->URL?=DSHDesktopApplication.installedURL){
  self.resolve=resolve;self.runner=runner;self.desktopApplication=desktopApplication
 }
 func scan(force:Bool=false)->[String:AgentInstalledVersion]{
  var results:[String:AgentInstalledVersion]=[:]
  for(provider,name) in [("codex","codex"),("claude","claude")] {
   guard let executable=resolve(name),let attributes=try? FileManager.default.attributesOfItem(atPath:URL(fileURLWithPath:executable).resolvingSymlinksInPath().path),
         let modified=attributes[.modificationDate] as? Date else{
    cached.removeValue(forKey:provider);results[provider] = .init(version:L10n.text("未安装"),issue:"");continue
   }
   let fingerprint=Fingerprint(path:URL(fileURLWithPath:executable).resolvingSymlinksInPath().path,inode:(attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,size:(attributes[.size] as? NSNumber)?.uint64Value ?? 0,modified:modified)
   if !force,let old=cached[provider],old.0==fingerprint,old.1.issue.isEmpty {results[provider]=old.1;continue}
   let value:AgentInstalledVersion
   do {
    var environment=ProcessInfo.processInfo.environment;environment["PATH"]=AgentExecutable.searchPath()
    let result=try runner.run(.init(executable:executable,arguments:["--version"],environment:environment,timeout:4,workingDirectory:"/"))
    guard result.status==0,let text=String(data:result.stdout,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),!text.isEmpty,text.utf8.count<=512 else{throw AvatarAgentError.invalidResponse}
    value = .init(version:String(text.prefix(200)),issue:"")
   }catch{value = .init(version:L10n.text("检测失败"),issue:L10n.text("无法检测 Agent 版本，请重试。"))}
   cached[provider]=(fingerprint,value);results[provider]=value
  }
  results["deepseek"] = .init(version:desktopApplication().flatMap{DSHDesktopApplication.version(at:$0)} ?? L10n.text("未安装"),issue:"")
  return results
 }
}
