import Foundation

// Each reader stays on the conversation monitor's serial queue.
final class ClaudeConversationReader: @unchecked Sendable {
 private(set) var snapshot=CodexConversationSnapshot()
 private(set) var title=L10n.text("未命名对话")
 private(set) var cwd=""
 private let metadataOnly:Bool
 private let deriveTitle:Bool
 init(metadataOnly:Bool=false,deriveTitle:Bool=true){self.metadataOnly=metadataOnly;self.deriveTitle=deriveTitle}
 private var named=false
 private var offset:UInt64=0
 private var fileIdentity:UInt64?
 private var pending=Data()
 private var droppingLine=false
 private var messageID=0
 private let limit=1_048_576
 private let dateParser:ISO8601DateFormatter={let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f}()
 func poll(_ url: URL) throws -> CodexConversationSnapshot {
  let values=try FileManager.default.attributesOfItem(atPath:url.path)
  guard values[.type] as? FileAttributeType == .typeRegular else {throw CocoaError(.fileReadUnsupportedScheme)}
  let size=(values[.size] as? NSNumber)?.uint64Value ?? 0
  let identity=(values[.systemFileNumber] as? NSNumber)?.uint64Value
  if identity != fileIdentity || size<offset {
   snapshot=CodexConversationSnapshot();offset=0;pending.removeAll();droppingLine=false;title=L10n.text("未命名对话");named=false;cwd="";fileIdentity=identity
  }
  if offset==0 && size>UInt64(limit) {offset=size-UInt64(limit);droppingLine=true}
  let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
  try file.seek(toOffset:offset)
  let data=try file.read(upToCount:limit) ?? Data();offset+=UInt64(data.count)
  pending.append(data)
  while let end=pending.firstIndex(of:10) {
   let line=Data(pending[..<end]);pending.removeSubrange(...end)
   if droppingLine {droppingLine=false;continue}
   consume(line)
  }
  if pending.count>limit {pending.removeAll();droppingLine=true}
  return snapshot
 }
 private func consume(_ line:Data){
  guard let root=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any],root["isSidechain"] as? Bool != true,root["isMeta"] as? Bool != true else{return}
  if let value=root["cwd"] as? String {cwd=value}
  if let value=root["customTitle"] as? String,!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {title=String(value.prefix(200));named=true}
  let type=root["type"] as? String
  guard ["user","assistant"].contains(type ?? ""),let message=root["message"] as? [String:Any] else{return}
  let blocks=message["content"] as? [[String:Any]] ?? []
  let text=(message["content"] as? String) ?? blocks.compactMap{block->String? in guard block["type"] as? String=="text" else{return nil};return block["text"] as? String}.joined(separator:"\n")
  let date=(root["timestamp"] as? String).flatMap{dateParser.date(from:$0) ?? ISO8601DateFormatter().date(from:$0)}
  // SDK Stop writes a synthetic user marker instead of a final assistant answer.
  if type=="user",["[Request interrupted by user]","[Request interrupted by user for tool use]"].contains(text) {
   snapshot.state="cancelled";snapshot.progress="";snapshot.completionID=nil;snapshot.updatedAt=date
   return
  }
  if metadataOnly {
   if deriveTitle,type=="user",!text.isEmpty,!named,L10n.notice(title)==L10n.text("未命名对话") {title=String(text.prefix(200))}
   if type=="user" {snapshot.state="working";snapshot.completionID=nil}
   if type=="assistant" {
    snapshot.state="working"
    if message["stop_reason"] as? String=="end_turn",!text.isEmpty {
     snapshot.state="completed";snapshot.completionID=(root["uuid"] as? String) ?? (root["timestamp"] as? String)
    }
   }
   snapshot.updatedAt=date
   return
  }
  if type=="user",!text.isEmpty {
   snapshot.state="working";snapshot.progress="";snapshot.completionID=nil
   if !named && L10n.notice(title)==L10n.text("未命名对话") {title=String(text.prefix(200))}
  }
  if type=="assistant" {
   snapshot.state="working"
   if !text.isEmpty {snapshot.progress=String(text.prefix(600))}
   if message["stop_reason"] as? String=="end_turn",!text.isEmpty {snapshot.state="completed";snapshot.completionID=(root["uuid"] as? String) ?? (root["timestamp"] as? String)}
  }
  snapshot.updatedAt=date
  guard !text.isEmpty else{return}
  messageID+=1;snapshot.messages.append(.init(id:messageID,role:type!,text:String(text.prefix(12000))))
  snapshot.messages=Array(snapshot.messages.suffix(40))
 }
}

final class LocalConversationReader: @unchecked Sendable {
 let claude:ClaudeConversationReader?
 private let codex:CodexConversationReader?
 init(path:String){if LocalConversationProvider.isClaude(path){claude=ClaudeConversationReader();codex=nil}else{codex=CodexConversationReader();claude=nil}}
 func poll(_ url:URL)throws->CodexConversationSnapshot {if let claude{return try claude.poll(url)};return try codex!.poll(url)}
}
enum LocalConversationProvider {
 static func isClaudeCowork(_ path:String)->Bool {
  let url=URL(fileURLWithPath:path),name=url.deletingPathExtension().lastPathComponent
  return url.pathExtension=="json" && url.pathComponents.contains("local-agent-mode-sessions") && name.hasPrefix("local_") && UUID(uuidString:String(name.dropFirst(6))) != nil
 }
 static func isClaudeDesktop(_ path:String)->Bool {
  let url=URL(fileURLWithPath:path),name=url.deletingPathExtension().lastPathComponent
  return isClaudeCowork(path) || url.pathExtension=="json" && url.pathComponents.contains("claude-code-sessions") && name.hasPrefix("local_") && UUID(uuidString:String(name.dropFirst(6))) != nil
 }
 static func claudeDesktopURL(_ path:String)->URL? {
  guard isClaudeDesktop(path) else{return nil}
  return URL(string:"claude://claude.ai/"+(isClaudeCowork(path) ? "cowork/":"epitaxy/")+URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent)
 }
 static func isClaude(_ path:String)->Bool {isClaudeDesktop(path) || URL(fileURLWithPath:path).pathExtension=="jsonl" && UUID(uuidString:URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent) != nil}
 static func isDSH(_ path:String)->Bool {path.contains("/storages/session_projcache/sessions/") && URL(fileURLWithPath:path).pathExtension=="json"}
 static func provider(_ path:String)->String {isDSH(path) ? "deepseek":isClaude(path) ? "claude":"codex"}
 static func label(_ path:String)->String {isDSH(path) ? "DeepSeek Harness":isClaudeCowork(path) ? "Claude Cowork":isClaudeDesktop(path) ? "Claude Desktop":isClaude(path) ? "Claude Code":"Codex"}
 static func openActionLabel(_ path:String)->String {isDSH(path) ? L10n.text("打开 DeepSeek Harness"):isClaudeDesktop(path) ? L10n.text("在 Claude Desktop 中打开"):isClaude(path) ? L10n.text("复制 Claude Code 会话命令"):L10n.text("在 Codex 中打开")}
 static func metadataOnly(_ path:String)->Bool {isClaude(path) || isDSH(path)}
 static func resumeCommand(_ path:String)->String? {
  guard isClaude(path),URL(fileURLWithPath:path).pathExtension=="jsonl" else{return nil}
  return "claude --resume "+URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent
 }
}

struct ClaudeDesktopSessionRecord {
 let path:String
 let cliID:String
 let title:String
 let lastActivity:Double
}
final class ClaudeDesktopSessionIndex: @unchecked Sendable {
 static var roots:[URL] {
  let base=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
  return ["Claude","Claude-3p"].map{base.appendingPathComponent($0+"/claude-code-sessions")}
 }
 private let roots:[URL]
 private let untitled:()->String
 private struct Cached {let size:UInt64;let date:Date;let record:ClaudeDesktopSessionRecord?}
 private var cached:[String:Cached]=[:]
 init(roots:[URL]=ClaudeDesktopSessionIndex.roots,untitled:@escaping ()->String={L10n.text("Claude Desktop 会话")}){self.roots=roots;self.untitled=untitled}
 func records()->[String:ClaudeDesktopSessionRecord] {
  var result:[String:ClaudeDesktopSessionRecord]=[:],seen=Set<String>(),count=0
  let fm=FileManager.default
  for input in roots {
   let root=input.standardizedFileURL.resolvingSymlinksInPath()
   func children(_ directory:URL)->[URL] {
    Array(((try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []).prefix(512)).filter{$0.resolvingSymlinksInPath().path.hasPrefix(root.path+"/")}
   }
   // Only account/org metadata; never search project workspaces or credential stores.
   for account in children(root).prefix(16) {
    for org in children(account).prefix(32) {
     for file in children(org) where LocalConversationProvider.isClaudeDesktop(file.path) {
      guard count<512 else{break};count+=1;seen.insert(file.path)
      guard let attributes=try? fm.attributesOfItem(atPath:file.path),attributes[.type] as? FileAttributeType == .typeRegular,
            let size=(attributes[.size] as? NSNumber)?.uint64Value,size<=1_048_576,
            let date=attributes[.modificationDate] as? Date else{continue}
      let entry:Cached
      if let old=cached[file.path],old.size==size,old.date==date {entry=old}
      else {
       var record:ClaudeDesktopSessionRecord?
       if let data=try? Data(contentsOf:file),data.count<=1_048_576,
          let row=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
          row["sessionId"] as? String==file.deletingPathExtension().lastPathComponent,
          row["isArchived"] as? Bool==false,let raw=row["cliSessionId"] as? String,let uuid=UUID(uuidString:raw) {
        let title=(row["title"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        record = .init(path:file.path,cliID:uuid.uuidString.lowercased(),title:String(title.prefix(200)),lastActivity:(row["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0)
       }
       entry=Cached(size:size,date:date,record:record);cached[file.path]=entry
      }
      if let record=entry.record,(result[record.cliID]?.lastActivity ?? -.infinity)<record.lastActivity {
       // Cache source titles verbatim; generated labels follow the active language.
       result[record.cliID] = .init(path:record.path,cliID:record.cliID,title:record.title.isEmpty ? untitled():record.title,lastActivity:record.lastActivity)
      }
     }
    }
   }
  }
  cached=cached.filter{seen.contains($0.key)}
  return result
 }
}

final class ClaudeSessionDiscovery: @unchecked Sendable {
 static var configurationHome:URL {URL(fileURLWithPath:ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)}
 private let home:URL
 private let listing:()throws->[ClaudeLiveSession]
 private let desktopIndex:ClaudeDesktopSessionIndex
 private let coworkDiscovery:ClaudeCoworkSessionDiscovery
 private let untitled:()->String
 private var readers:[String:ClaudeConversationReader]=[:]
 private var previous:[String:CodexDiscoveredSession]=[:]
 private var sourceTitles:[String:String]=[:]
 private var completionSequence=0
 private(set) var connected=false
 private(set) var connectionNotice=""
 init(home:URL=ClaudeSessionDiscovery.configurationHome,listing:@escaping()throws->[ClaudeLiveSession]={try ClaudeSessionStatus.query()},desktopRoots:[URL]=ClaudeDesktopSessionIndex.roots,coworkDiscovery:ClaudeCoworkSessionDiscovery?=nil,untitled:@escaping ()->String={L10n.text("Claude Code 会话")}){
  self.home=home.standardizedFileURL.resolvingSymlinksInPath();self.listing=listing;self.desktopIndex=ClaudeDesktopSessionIndex(roots:desktopRoots);self.coworkDiscovery=coworkDiscovery ?? ClaudeCoworkSessionDiscovery();self.untitled=untitled
 }
 func scan(now:Date=Date())->[CodexDiscoveredSession]{
  let cowork=coworkDiscovery.scan(now:now)
  let live:[ClaudeLiveSession]
  do {live=try listing();connected=true;connectionNotice=""}
  catch {
   connected=false
   switch error {
   case AvatarAgentError.invalidResponse:connectionNotice=L10n.text("Claude Code 会话格式暂不兼容，请检查 PetLink 更新后重试。")
   case AvatarAgentError.timedOut:connectionNotice=L10n.text("Claude Code 状态查询超时，请重试。")
   default:connectionNotice=L10n.text("Claude Code 自动连接暂不可用，请重试；若持续出现，请检查软件更新。")
   }
   previous.removeAll();readers.removeAll();sourceTitles.removeAll()
   if coworkDiscovery.connected {connected=true;connectionNotice=""}
   if !coworkDiscovery.connectionNotice.isEmpty {connectionNotice=coworkDiscovery.connectionNotice}
   return cowork
  }
  let projects=home.appendingPathComponent("projects").resolvingSymlinksInPath()
  let folders=Array(((try? FileManager.default.contentsOfDirectory(at:projects,includingPropertiesForKeys:nil)) ?? []).prefix(512)).filter{$0.resolvingSymlinksInPath().path.hasPrefix(projects.path+"/")}
  let desktop=desktopIndex.records()
  var found:[CodexDiscoveredSession]=[],seen=Set<String>()
  for row in live.prefix(256) {
   guard let rawID=row.sessionId,let uuid=UUID(uuidString:rawID) else{continue}
   let id=uuid.uuidString.lowercased();guard !coworkDiscovery.cliSessionIDs.contains(id),seen.insert(id).inserted else{continue}
   let old=previous[id],record=desktop[id]
   let file=folders.lazy.map{$0.appendingPathComponent(id+".jsonl")}.first{FileManager.default.fileExists(atPath:$0.path) && $0.resolvingSymlinksInPath().path.hasPrefix(projects.path+"/")}
   var state=row.activity
   var title=record?.title ?? sourceTitles[id] ?? ""
   // Desktop SDKs register a live process but may omit agents activity fields.
   // Only a mapped Desktop session can use transcript lifecycle as the fallback.
   if (["working","waiting_approval"].contains(state) || record != nil),let file {
    let reader=readers[id] ?? ClaudeConversationReader(metadataOnly:true);readers[id]=reader
    if let snapshot=try? reader.poll(file) {
     if state=="unknown",record != nil,(row.pid ?? 0)>0 {state=snapshot.state}
     if record==nil,L10n.notice(reader.title) != L10n.text("未命名对话") {title=reader.title}
    }
   }
   let active=["working","waiting_approval"].contains(state)
   guard active || old != nil && !(record==nil && old.map{LocalConversationProvider.isClaudeDesktop($0.path)}==true) else{continue}
   let path=record?.path ?? file?.resolvingSymlinksInPath().path ?? old?.path ?? home.appendingPathComponent("sessions/"+id+".jsonl").path
   let directory=URL(fileURLWithPath:row.cwd).lastPathComponent
   // Claude's default live name can slug and lowercase the directory before
   // adding two hex digits. It is not a user title and must not replace one.
   let slug=directory.lowercased().replacingOccurrences(of:"[^a-z0-9]+",with:"-",options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:"-"))
   let generatedNames=[directory,slug].filter{!$0.isEmpty}
   if record==nil,let name=row.name?.trimmingCharacters(in:.whitespacesAndNewlines),!name.isEmpty,
      UUID(uuidString:name)==nil,
      !generatedNames.contains(where:{name.range(of:"^"+NSRegularExpression.escapedPattern(for:$0)+"-[0-9a-fA-F]{2}$",options:.regularExpression) != nil}) {
    title=String(name.prefix(200))
   }
   var snapshot=CodexConversationSnapshot();snapshot.updatedAt=now;snapshot.state=state
   if state=="idle",old != nil {snapshot.state="completed"}
   switch snapshot.state {
   case "working":snapshot.progress=L10n.text("正在执行…")
   case "waiting_approval":snapshot.progress=row.waitingFor=="input needed" ? L10n.text("等待你的输入"):L10n.text("等待你的确认")
   case "completed":
    snapshot.progress=L10n.text("已完成")
    if old?.snapshot.state=="completed" {snapshot.completionID=old?.snapshot.completionID}
    else {completionSequence+=1;snapshot.completionID=id+":"+String(completionSequence)}
   case "failed":snapshot.progress=L10n.text("执行未完成")
   case "cancelled":snapshot.progress=L10n.text("已停止")
   default:snapshot.progress=""
   }
   if record==nil {sourceTitles[id]=title}
   if title.isEmpty {title=untitled()}
   found.append(.init(path:path,title:title,snapshot:snapshot));previous[id]=found.last!
  }
  previous=previous.filter{seen.contains($0.key)};readers=readers.filter{previous[$0.key] != nil};sourceTitles=sourceTitles.filter{previous[$0.key] != nil}
  if !coworkDiscovery.connectionNotice.isEmpty {connectionNotice=coworkDiscovery.connectionNotice}
  return found+cowork
 }
}
