import Foundation
import Darwin

struct DSHDesktopSessionLease:Equatable {
 let lockPath:String
 let processIdentity:String
 var startedAt:Date = .distantPast
}

// Confined to the conversation monitor's serial queue.
final class DSHDesktopSessionDiscovery: @unchecked Sendable {
 private let leases:()->[DSHDesktopSessionLease]
 private let hostRunning:()->Bool
 private struct Metadata:Decodable {
  struct Identity:Decodable {let formatVersion:Int?;let createdAt:Int64}
  struct Row<Value:Decodable>:Decodable {let ver:Int;let seq:Int64;let val:Value}
  struct Boundary:Decodable {let openTurnStartSeq:Int64?;let lastTurn:Int}
  struct Rows:Decodable {var title:Row<String?>?;let turnBoundary:Row<Boundary>?}
  struct Record:Decodable {let identity:Identity;var rows:Rows}
  let version:Int;var record:Record
 }
 private struct Envelope:Decodable {struct Record:Decodable {let identity:Metadata.Identity};let version:Int;let record:Record}
 private struct Fingerprint:Equatable {let inode:UInt64;let size:Int64;let seconds:Int;let nanoseconds:Int}
 private struct Cached {let fingerprint:Fingerprint;let metadata:Metadata?;let issue:String}
 private struct Previous {let item:CodexDiscoveredSession;let createdAt:Int64;let end:Date?}
 private var cache:[String:Cached]=[:]
 private var previous:[String:Previous]=[:]
 private(set) var connected=false
 private(set) var connectionNotice=""
 private(set) var decodedFiles=0
 var retainedTitleCharacters:Int {cache.values.reduce(0){$0+($1.metadata?.record.rows.title?.val?.count ?? 0)}}
 var retainedTitleBytes:Int {cache.values.reduce(0){$0+($1.metadata?.record.rows.title?.val?.utf8.count ?? 0)}}
 init(leases:(()->[DSHDesktopSessionLease])?=nil,hostRunning:(()->Bool)?=nil){
  let inspector=DSHDesktopProcessInspector()
  self.leases=leases ?? {inspector.scan()}
  self.hostRunning=hostRunning ?? {leases == nil && inspector.hostRunning}
 }
 func scan(now:Date=Date())->[CodexDiscoveredSession]{
  connected=false;connectionNotice=""
  var paths=Set<String>(),budget=8_388_608,results:[CodexDiscoveredSession]=[],next:[String:Previous]=[:]
  let live=leases()
  connected=hostRunning()
  for lease in live.prefix(256) {
   guard let path=Self.metadataPath(for:lease.lockPath),paths.insert(path).inserted else{continue}
   guard let meta=read(path,budget:&budget) else{continue}
   connected=true
   guard let boundary=meta.record.rows.turnBoundary else{continue}
   if boundary.val.openTurnStartSeq != nil {
    guard let fingerprint=cache[path]?.fingerprint,
          Double(fingerprint.seconds)+Double(fingerprint.nanoseconds)/1_000_000_000>=lease.startedAt.timeIntervalSince1970 else{continue}
    let rawTitle=meta.record.rows.title?.val?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
    var snapshot=CodexConversationSnapshot();snapshot.state="working";snapshot.progress=L10n.text("正在执行");snapshot.updatedAt=now
    let item=CodexDiscoveredSession(path:path,title:rawTitle.isEmpty ? L10n.text("未命名对话"):String(rawTitle.prefix(200)),snapshot:snapshot)
    next[path]=Previous(item:item,createdAt:meta.record.identity.createdAt,end:nil);results.append(item)
   }
  }
  // A final cache flush precedes a normal writer exit. An orphaned open turn
  // is a crash and must disappear without celebrating successful completion.
  for (path,old) in previous where next[path]==nil {
   guard next.count<512 else{break}
   guard let meta=read(path,budget:&budget,reportFailure:false),meta.record.identity.createdAt==old.createdAt,
         let boundary=meta.record.rows.turnBoundary,boundary.val.openTurnStartSeq==nil,boundary.val.lastTurn>0 else{continue}
   if let end=old.end {
    if now<end {next[path]=old;results.append(old.item)}
    continue
   }
   var snapshot=CodexConversationSnapshot();snapshot.state="ended";snapshot.progress=L10n.text("本轮已结束");snapshot.updatedAt=now
   snapshot.completionID="dsh:\(old.createdAt):\(boundary.val.lastTurn):\(boundary.seq)"
   let item=CodexDiscoveredSession(path:path,title:old.item.title,snapshot:snapshot)
   next[path]=Previous(item:item,createdAt:old.createdAt,end:now.addingTimeInterval(8));results.append(item)
  }
  previous=next
  cache=cache.filter{paths.contains($0.key) || next[$0.key] != nil}
  return results.sorted{$0.path<$1.path}
 }
 static func metadataPath(for lockPath:String)->String? {
  let lock=URL(fileURLWithPath:lockPath).standardizedFileURL.resolvingSymlinksInPath()
  guard lock.lastPathComponent=="session.lock" else{return nil}
  let id=lock.deletingLastPathComponent().lastPathComponent
  // This is also the shipped JSON storage backend's safe record-key contract.
  guard id.range(of:"^[A-Za-z0-9_-]{1,200}$",options:.regularExpression) != nil else{return nil}
  let sessions=lock.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  guard sessions.lastPathComponent=="sessions" else{return nil}
  return sessions.deletingLastPathComponent().appendingPathComponent("storages/session_projcache/sessions/"+id+".json").path
 }
 private func read(_ path:String,budget:inout Int,reportFailure:Bool=true)->Metadata? {
  func failedRead(){if reportFailure{connectionNotice=L10n.text("部分 DeepSeek Harness 会话状态无法读取，请重试。")}}
  let url=URL(fileURLWithPath:path)
  guard url.resolvingSymlinksInPath().path==url.standardizedFileURL.path else{failedRead();return nil}
  let fd=Darwin.open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);guard fd>=0 else{failedRead();return nil};defer{Darwin.close(fd)}
  var attributes=stat()
  guard fstat(fd,&attributes)==0,attributes.st_mode & S_IFMT==S_IFREG,attributes.st_size>0,attributes.st_size<=1_048_576 else{failedRead();return nil}
  let fingerprint=Fingerprint(inode:attributes.st_ino,size:attributes.st_size,seconds:attributes.st_mtimespec.tv_sec,nanoseconds:attributes.st_mtimespec.tv_nsec)
  if let cached=cache[path],cached.fingerprint==fingerprint {
   if reportFailure,!cached.issue.isEmpty {connectionNotice=cached.issue}
   return cached.metadata
  }
  guard budget>=attributes.st_size else{return nil};budget-=Int(attributes.st_size)
  let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
  guard let data=try? handle.read(upToCount:Int(attributes.st_size)),data.count==attributes.st_size else{failedRead();return nil}
  decodedFiles+=1
  let decoder=JSONDecoder(),envelope=try? JSONDecoder().decode(Envelope.self,from:data)
  let predecessor=envelope.map{($0.record.identity.formatVersion ?? 0)<4} ?? false
  var metadata=predecessor ? nil:try? decoder.decode(Metadata.self,from:data)
  var issue=predecessor ? "":L10n.text("DeepSeek Harness 会话状态暂无法读取，请重试。")
  if var meta=metadata {
   let boundary=meta.record.rows.turnBoundary
   // Desktop can hold old sessions whose disposable cache predates format
   // identity. Such caches are not activity evidence or connection failures.
   if meta.record.identity.formatVersion == nil || (meta.record.identity.formatVersion ?? 0)<4 {metadata=nil;issue=""}
   else if meta.version != 7 || meta.record.identity.formatVersion != 4 || (boundary.map{$0.ver != 2} ?? false) || (meta.record.rows.title.map{$0.ver != 1} ?? false) {metadata=nil;issue=L10n.text("DeepSeek Harness 会话格式暂不兼容，请检查 PetLink 更新后重试。")}
   else if meta.record.identity.createdAt<0 || (boundary.map{row in row.seq < -1 || row.val.lastTurn<0 || (row.val.openTurnStartSeq.map{$0<0 || $0>row.seq} ?? false) || (meta.record.rows.title.map{$0.seq>row.seq} ?? false)} ?? false) {metadata=nil}
   else {
    if let title=meta.record.rows.title,let value=title.val {
     var bytes=Array(value.utf8.prefix(2048)),text=String(bytes:value.utf8.prefix(2048),encoding:.utf8)
     while text==nil && !bytes.isEmpty {bytes.removeLast();text=String(bytes:bytes,encoding:.utf8)}
     meta.record.rows.title=Metadata.Row(ver:title.ver,seq:title.seq,val:String((text ?? "").prefix(200)))
    }
    metadata=meta
   }
  }
  cache[path]=Cached(fingerprint:fingerprint,metadata:metadata,issue:metadata==nil ? issue:"")
  if reportFailure,metadata==nil {connectionNotice=issue}
  return metadata
 }
}

// Only the installed Desktop main process's own Host child can authorize
// projection reads. CLI, node, renderers, and history readers do not qualify.
final class DSHDesktopProcessInspector {
 private let application:()->URL?
 private(set) var hostRunning=false
 init(application:@escaping()->URL?=DSHDesktopApplication.installedURL){self.application=application}
 func scan()->[DSHDesktopSessionLease] {
  hostRunning=false
  guard let app=application(),DSHDesktopApplication.version(at:app) != nil,
        let executable=DSHDesktopApplication.executable(at:app) else{return []}
  let runtime=DSHDesktopApplication.canonicalPath(app.path)+"/Contents/Resources/app.asar/dsh"
  var pids=[Int32](repeating:0,count:min(8192,max(0,Int(proc_listallpids(nil,0)))+64))
  let count=pids.withUnsafeMutableBytes{proc_listallpids($0.baseAddress,Int32($0.count))}
  var leases:[DSHDesktopSessionLease]=[]
  for pid in pids.prefix(min(pids.count,max(0,Int(count)))) where pid>0 {
   if leases.count>=256 {break}
   var info=proc_bsdinfo()
   let bytes=withUnsafeMutablePointer(to:&info){proc_pidinfo(pid,PROC_PIDTBSDINFO,0,$0,Int32(MemoryLayout<proc_bsdinfo>.size))}
   guard bytes==MemoryLayout<proc_bsdinfo>.size,info.pbi_uid==getuid(),info.pbi_status != SZOMB,
         processPath(pid)==executable,processPath(Int32(info.pbi_ppid))==executable,
         Self.isHost(arguments:arguments(pid),runtime:runtime) else{continue}
   hostRunning=true
   let identity="\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
   var fds=[proc_fdinfo](repeating:proc_fdinfo(),count:4096)
   let size=fds.withUnsafeMutableBytes{proc_pidinfo(pid,PROC_PIDLISTFDS,0,$0.baseAddress,Int32($0.count))}
   for fd in fds.prefix(min(fds.count,max(0,Int(size))/MemoryLayout<proc_fdinfo>.size)) where fd.proc_fdtype==PROX_FDTYPE_VNODE {
    if leases.count>=256 {break}
    var vnode=vnode_fdinfowithpath()
    let bytes=withUnsafeMutablePointer(to:&vnode){proc_pidfdinfo(pid,Int32(fd.proc_fd),PROC_PIDFDVNODEPATHINFO,$0,Int32(MemoryLayout<vnode_fdinfowithpath>.size))}
    guard bytes==MemoryLayout<vnode_fdinfowithpath>.size,vnode.pfi.fi_openflags & 2 != 0 else{continue}
    let path=withUnsafePointer(to:&vnode.pvip.vip_path){$0.withMemoryRebound(to:CChar.self,capacity:1024){String(cString:$0)}}
    guard path.hasSuffix("/session.lock"),DSHDesktopSessionDiscovery.metadataPath(for:path) != nil else{continue}
    var disk=stat()
    guard lstat(path,&disk)==0,disk.st_mode & S_IFMT==S_IFREG,disk.st_ino==vnode.pvip.vip_vi.vi_stat.vst_ino,disk.st_dev==vnode.pvip.vip_vi.vi_stat.vst_dev else{continue}
    leases.append(.init(lockPath:path,processIdentity:identity,startedAt:Date(timeIntervalSince1970:Double(info.pbi_start_tvsec)+Double(info.pbi_start_tvusec)/1_000_000)))
   }
  }
  return leases
 }
 static func isHost(arguments:[String],runtime:String)->Bool {
  func canonical(_ value:String)->String {
   guard value.hasPrefix("/"),let split=value.range(of:"/Contents/Resources/") else{return value}
   let app=DSHDesktopApplication.canonicalPath(String(value[..<split.lowerBound]))
   return app+value[split.lowerBound...]
  }
  let paths=Set(arguments.map(canonical))
  return paths.contains(canonical(runtime)+"/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js") && paths.contains(canonical(runtime))
 }
 private func processPath(_ pid:Int32)->String? {
  var path=[CChar](repeating:0,count:4096)
  guard proc_pidpath(pid,&path,UInt32(path.count))>0 else{return nil}
  return String(cString:path)
 }
 private func arguments(_ pid:Int32)->[String] {
  var mib:[Int32]=[CTL_KERN,KERN_PROCARGS2,pid],bytes=[UInt8](repeating:0,count:262144),size=262144
  let result=mib.withUnsafeMutableBufferPointer{m in bytes.withUnsafeMutableBytes{b in sysctl(m.baseAddress,3,b.baseAddress,&size,nil,0)}}
  guard result==0,size>4 else{return []}
  let argc=bytes.withUnsafeBytes{$0.loadUnaligned(as:Int32.self)}
  guard argc>0,argc<4096 else{return []}
  // Stop at argc; environment values are never decoded or retained.
  return bytes.prefix(size).dropFirst(4).split(separator:0).dropFirst().prefix(min(Int(argc),12)).compactMap{String(bytes:$0,encoding:.utf8)}
 }
}
