import Foundation
import SQLite3

struct CodexDiscoveredSession {
 let path:String
 let title:String
 let snapshot:CodexConversationSnapshot
}

// Local metadata and bounded rollout tails only. No Codex writes or network calls.
final class CodexSessionDiscovery: @unchecked Sendable {
 private(set) var connected=false
 private(set) var connectionNotice=""
 private let home:URL
 private var readers:[String:CodexConversationReader]=[:]
 private var userSources:[String:(UInt64,Bool)]=[:]
 init(home:URL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)){self.home=home}
 func scan(now:Date=Date())->[CodexDiscoveredSession] {
  connected=false;connectionNotice=""
  var results:[CodexDiscoveredSession]=[],seen=Set<String>()
  for item in metadata() {
   let url=URL(fileURLWithPath:item.path).standardizedFileURL.resolvingSymlinksInPath(),path=url.path
   // Never follow a metadata path outside the configured local Codex home.
   guard path.hasPrefix(home.standardizedFileURL.resolvingSymlinksInPath().path+"/"),url.pathExtension=="jsonl",
         let attributes=try? FileManager.default.attributesOfItem(atPath:path),let modified=attributes[.modificationDate] as? Date,
         now.timeIntervalSince(modified)<120 else{continue}
   seen.insert(path)
   let identity=(attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
   let userSource:Bool?
   if let cached=userSources[path],cached.0==identity {userSource=cached.1}else{userSource=isUserConversation(url);if let userSource{userSources[path]=(identity,userSource)}}
   guard userSource==true else{continue}
   let reader=readers[path] ?? CodexConversationReader();readers[path]=reader
   guard let snapshot=try? reader.poll(url),snapshot.state=="working",let date=snapshot.updatedAt,
         now.timeIntervalSince(date)>=(-10),now.timeIntervalSince(date)<120 else{continue}
   let title=item.title.trimmingCharacters(in:.whitespacesAndNewlines)
   results.append(.init(path:path,title:title.isEmpty ? L10n.text("未命名对话"):String(title.prefix(200)),snapshot:snapshot))
  }
  readers=readers.filter{seen.contains($0.key)}
  userSources=userSources.filter{seen.contains($0.key)}
  return results
 }
 private func isUserConversation(_ url:URL)->Bool? {
  guard let file=try? FileHandle(forReadingFrom:url) else{return nil};defer{try? file.close()}
  var header=Data(),complete=false
  while header.count<1_048_576 {
   guard let part=try? file.read(upToCount:min(16384,1_048_576-header.count)),!part.isEmpty else{return nil}
   if let end=part.firstIndex(of:10){header.append(part[..<end]);complete=true;break}
   header.append(part)
  }
  guard complete,let root=(try? JSONSerialization.jsonObject(with:header)) as? [String:Any] else{return nil}
  guard root["type"] as? String=="session_meta",let payload=root["payload"] as? [String:Any],let source=payload["source"] as? [String:Any] else{return true}
  return source["subagent"]==nil
 }
 func title(for path:String)->String {
  if let item=metadata().first(where:{$0.path==path}) {return item.title.isEmpty ? L10n.text("未命名对话"):String(item.title.prefix(200))}
  let titles=readTitles()
  if let match=titles.first(where:{path.hasSuffix($0.key+".jsonl")}){return String(match.value.prefix(200))}
  return L10n.text("未命名对话")
 }
 private func metadata()->[(path:String,title:String)] {
  let files=(try? FileManager.default.contentsOfDirectory(at:home,includingPropertiesForKeys:nil)) ?? []
  let databases=files.filter{$0.lastPathComponent.range(of:"^state_[0-9]+\\.sqlite$",options:.regularExpression) != nil}.sorted{
   let a=Int($0.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0,b=Int($1.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? 0;return a>b
  }
  guard let database=databases.first else{return []}
  var db:OpaquePointer?
  guard sqlite3_open_v2(database.path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX,nil)==SQLITE_OK else{if db != nil{sqlite3_close(db)};connectionNotice=L10n.text("无法读取 Codex 会话状态，请重试。");return []}
  defer{sqlite3_close(db)}
  sqlite3_busy_timeout(db,100)
  var schema:OpaquePointer?,columns=Set<String>()
  guard sqlite3_prepare_v2(db,"PRAGMA table_info(threads)",-1,&schema,nil)==SQLITE_OK else{sqlite3_finalize(schema);connectionNotice=L10n.text("无法读取 Codex 会话状态，请重试。");return []}
  var schemaStatus=sqlite3_step(schema)
  while schemaStatus==SQLITE_ROW {if let column=sqlite3_column_text(schema,1) {columns.insert(String(cString:column))};schemaStatus=sqlite3_step(schema)}
  sqlite3_finalize(schema)
  guard schemaStatus==SQLITE_DONE else{connectionNotice=L10n.text("无法读取 Codex 会话状态，请重试。");return []}
  guard Set(["id","rollout_path","title","archived","updated_at"]).isSubset(of:columns) else{connectionNotice=L10n.text("Codex 会话格式暂不兼容，请检查 PetLink 更新后重试。");return []}
  var statement:OpaquePointer?
  let sql="SELECT id, rollout_path, title, "+(columns.contains("name") ? "name":"NULL")+" FROM threads WHERE archived=0 ORDER BY updated_at DESC LIMIT 256"
  guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else{connectionNotice=L10n.text("无法读取 Codex 会话状态，请重试。");return []}
  defer{sqlite3_finalize(statement)}
  let titles=readTitles()
  var items:[(path:String,title:String)]=[]
  var status=sqlite3_step(statement)
  while status==SQLITE_ROW {
   func string(_ column:Int32)->String {sqlite3_column_text(statement,column).map{String(cString:$0)} ?? ""}
   let name=string(3).trimmingCharacters(in:.whitespacesAndNewlines)
   let title=name.isEmpty ? titles[string(0)] ?? string(2):name
   items.append((string(1),String(title.prefix(200))))
   status=sqlite3_step(statement)
  }
  guard status==SQLITE_DONE else{connectionNotice=L10n.text("无法读取 Codex 会话状态，请重试。");return []}
  connected=true
  return items
 }
 private func readTitles()->[String:String] {
  let url=home.appendingPathComponent("session_index.jsonl")
  guard let file=try? FileHandle(forReadingFrom:url) else{return [:]};defer{try? file.close()}
  guard let size=try? file.seekToEnd() else{return [:]}
  let start=size>1_048_576 ? size-1_048_576:0
  guard (try? file.seek(toOffset:start)) != nil,let data=try? file.read(upToCount:1_048_576),let text=String(data:data,encoding:.utf8) else{return [:]}
  var titles:[String:String]=[:]
  for line in text.split(separator:"\n").dropFirst(start>0 ? 1:0) {
   guard let row=(try? JSONSerialization.jsonObject(with:Data(line.utf8))) as? [String:Any],let id=row["id"] as? String,let title=row["thread_name"] as? String,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{continue}
   titles[id]=title
  }
  return titles
 }
}
