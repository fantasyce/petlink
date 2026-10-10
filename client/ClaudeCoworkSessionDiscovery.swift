import Foundation
import Darwin

final class ClaudeCoworkSessionDiscovery: @unchecked Sendable {
 static var roots:[URL] {
  let base=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
  return ["Claude","Claude-3p"].map{base.appendingPathComponent($0+"/local-agent-mode-sessions")}
 }
 private struct Metadata:Decodable {let sessionId:String;let cliSessionId:String;let title:String?;let isArchived:Bool;let hostLoopMode:Bool?}
 private struct Registry:Decodable {
  let pid:Int;let sessionId:String;let kind:String;let entrypoint:String?;let pidDomain:String?;let procStart:String;let status:String?
 }
 private struct Fingerprint:Equatable {let inode:UInt64;let size:Int64;let seconds:Int;let nanoseconds:Int}
 private struct Cached {let fingerprint:Fingerprint;let metadata:Metadata?}
 private struct Previous {let item:CodexDiscoveredSession;let baseline:String?;let endsAt:Date?}
 private let roots:[URL]
 private let processMatches:(Int,String)->Bool
 private var cache:[String:Cached]=[:]
 private var readers:[String:ClaudeConversationReader]=[:]
 private var previous:[String:Previous]=[:]
 private(set) var connected=false
 private(set) var connectionNotice=""
 private(set) var cliSessionIDs=Set<String>()
 init(roots:[URL]=ClaudeCoworkSessionDiscovery.roots,processMatches:@escaping(Int,String)->Bool=ClaudeCoworkProcessIdentity.matches){self.roots=roots;self.processMatches=processMatches}
 func scan(now:Date=Date())->[CodexDiscoveredSession]{
  connected=false;connectionNotice="";cliSessionIDs.removeAll(keepingCapacity:true)
  let fm=FileManager.default
  var seen=Set<String>(),next:[String:Previous]=[:],remaining=8_388_608,recordCount=0,registryCount=0
  for input in roots {
   let root=input.standardizedFileURL.resolvingSymlinksInPath()
   func children(_ directory:URL)->[URL] {
    Array(((try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []).prefix(512)).filter{$0.resolvingSymlinksInPath().path.hasPrefix(root.path+"/")}
   }
   for account in children(root).prefix(16) {
    for org in children(account).prefix(32) {
     for file in children(org) where LocalConversationProvider.isClaudeCowork(file.path) {
      guard recordCount<512 else{break};recordCount+=1;seen.insert(file.path)
      guard let metadata=metadata(file,budget:&remaining),!metadata.isArchived,metadata.hostLoopMode==true,
            metadata.sessionId==file.deletingPathExtension().lastPathComponent,UUID(uuidString:metadata.cliSessionId) != nil else{continue}
      let runtime=org.appendingPathComponent(String(metadata.sessionId.dropFirst(6).prefix(8))+"/.claude")
      guard runtime.resolvingSymlinksInPath().path==runtime.standardizedFileURL.path else{continue}
      var live:Registry?
      for registry in children(runtime.appendingPathComponent("sessions")) where registry.pathExtension=="json" {
       guard registryCount<256 else{break};registryCount+=1
       guard let value:Registry=decode(registry,maxSize:65_536,budget:&remaining),value.sessionId.lowercased()==metadata.cliSessionId.lowercased(),
             value.pid>0,registry.deletingPathExtension().lastPathComponent==String(value.pid),value.pidDomain=="darwin",value.entrypoint=="local-agent",value.kind=="interactive",processMatches(value.pid,value.procStart) else{continue}
       guard ["busy","waiting","idle"].contains(value.status ?? "") else{connectionNotice=L10n.text("Claude Cowork 会话格式暂不兼容，请检查 PetLink 更新后重试。");continue}
       live=value;break
      }
      guard let live else{continue};connected=true;cliSessionIDs.insert(metadata.cliSessionId.lowercased())
      let old=previous[file.path]
      let reader=readers[file.path] ?? ClaudeConversationReader(metadataOnly:true,deriveTitle:false);readers[file.path]=reader
      let transcript=runtime.appendingPathComponent("projects/session/"+metadata.cliSessionId.lowercased()+".jsonl")
      // Runtime status decides activity; transcript lifecycle is used only to
      // distinguish an observed turn's final answer from Stop or an abrupt end.
      let result=transcript.resolvingSymlinksInPath().path==transcript.standardizedFileURL.path ? try? reader.poll(transcript):nil
      var snapshot=CodexConversationSnapshot();snapshot.updatedAt=now
      let title=String((metadata.title?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "").prefix(200))
      if live.status=="busy" || live.status=="waiting" {
       snapshot.state=live.status=="waiting" ? "waiting_approval":"working"
       snapshot.progress=live.status=="waiting" ? L10n.text("等待你的确认"):L10n.text("正在执行…")
       let baseline=old?.endsAt==nil && old != nil ? old?.baseline:result?.completionID
       next[file.path]=Previous(item:.init(path:file.path,title:title.isEmpty ? L10n.text("Cowork 会话"):title,snapshot:snapshot),baseline:baseline,endsAt:nil)
      }else if let old {
       if let endsAt=old.endsAt {
        if now<endsAt {next[file.path]=old}
       }else {
        if result?.state=="cancelled" {snapshot.state="cancelled";snapshot.progress=L10n.text("已停止")}
        else if result?.state=="completed",let id=result?.completionID,id != old.baseline {snapshot.state="completed";snapshot.progress=L10n.text("已完成");snapshot.completionID=id}
        else {snapshot.state="ended";snapshot.progress=L10n.text("本轮已结束")}
        next[file.path]=Previous(item:.init(path:file.path,title:title.isEmpty ? old.item.title:title,snapshot:snapshot),baseline:old.baseline,endsAt:now.addingTimeInterval(8))
       }
      }
     }
    }
   }
  }
  cache=cache.filter{seen.contains($0.key)};readers=readers.filter{next[$0.key] != nil}
  previous=next
  return next.values.map(\.item).sorted{$0.path<$1.path}
 }
 private func metadata(_ file:URL,budget:inout Int)->Metadata? {
  guard let data=read(file,maxSize:1_048_576,budget:&budget,cached:true) else{return cache[file.path]?.metadata}
  var value=try? JSONDecoder().decode(Metadata.self,from:data.data)
  if let item=value {value=Metadata(sessionId:item.sessionId,cliSessionId:item.cliSessionId,title:String((item.title ?? "").prefix(200)),isArchived:item.isArchived,hostLoopMode:item.hostLoopMode)}
  cache[file.path]=Cached(fingerprint:data.fingerprint,metadata:value)
  return value
 }
 private func decode<T:Decodable>(_ file:URL,maxSize:Int,budget:inout Int)->T? {
  guard let data=read(file,maxSize:maxSize,budget:&budget) else{return nil}
  return try? JSONDecoder().decode(T.self,from:data.data)
 }
 private func read(_ file:URL,maxSize:Int,budget:inout Int,cached:Bool=false)->(data:Data,fingerprint:Fingerprint)? {
  guard file.resolvingSymlinksInPath().path==file.standardizedFileURL.path else{cache.removeValue(forKey:file.path);return nil}
  let fd=Darwin.open(file.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);guard fd>=0 else{cache.removeValue(forKey:file.path);return nil};defer{Darwin.close(fd)}
  var attributes=stat()
  guard fstat(fd,&attributes)==0,attributes.st_mode & S_IFMT==S_IFREG,attributes.st_size>0,attributes.st_size<=maxSize else{cache.removeValue(forKey:file.path);return nil}
  let fingerprint=Fingerprint(inode:attributes.st_ino,size:attributes.st_size,seconds:attributes.st_mtimespec.tv_sec,nanoseconds:attributes.st_mtimespec.tv_nsec)
  if cached,cache[file.path]?.fingerprint==fingerprint {return nil}
  guard budget>=attributes.st_size else{cache.removeValue(forKey:file.path);return nil};budget-=Int(attributes.st_size)
  let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
  guard let data=try? handle.read(upToCount:Int(attributes.st_size)),data.count==attributes.st_size else{cache.removeValue(forKey:file.path);return nil}
  return (data,fingerprint)
 }
}

enum ClaudeCoworkProcessIdentity {
 static func matches(_ rawPID:Int,_ start:String)->Bool {
  guard rawPID>0,rawPID<=Int(Int32.max) else{return false}
  let pid=Int32(rawPID)
  var info=proc_bsdinfo()
  let count=withUnsafeMutablePointer(to:&info){proc_pidinfo(pid,PROC_PIDTBSDINFO,0,$0,Int32(MemoryLayout<proc_bsdinfo>.size))}
  guard count==MemoryLayout<proc_bsdinfo>.size,info.pbi_uid==getuid(),info.pbi_status != SZOMB else{return false}
  let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="EEE MMM d HH:mm:ss yyyy"
  guard let expected=formatter.date(from:start),Int(expected.timeIntervalSince1970)==Int(info.pbi_start_tvsec),let executable=path(pid),executable.hasSuffix("/claude.app/Contents/MacOS/claude"),executable.contains("/claude-code/") else{return false}
  var parent=Int32(info.pbi_ppid)
  for _ in 0..<8 {
   guard parent>1,let executable=path(parent) else{return false}
   if executable.hasSuffix("/Claude.app/Contents/MacOS/Claude"){return true}
   var ancestor=proc_bsdinfo()
   let bytes=withUnsafeMutablePointer(to:&ancestor){proc_pidinfo(parent,PROC_PIDTBSDINFO,0,$0,Int32(MemoryLayout<proc_bsdinfo>.size))}
   guard bytes==MemoryLayout<proc_bsdinfo>.size,ancestor.pbi_uid==getuid(),ancestor.pbi_status != SZOMB else{return false}
   parent=Int32(ancestor.pbi_ppid)
  }
  return false
 }
 private static func path(_ pid:Int32)->String? {
  var bytes=[CChar](repeating:0,count:4096)
  guard proc_pidpath(pid,&bytes,UInt32(bytes.count))>0 else{return nil}
  return String(cString:bytes)
 }
}
