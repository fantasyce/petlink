import Foundation

struct CodexLocalMessage: Identifiable, Equatable {
 let id: Int
 let role: String
 let text: String
}

struct CodexConversationSnapshot: Equatable {
 var messages: [CodexLocalMessage] = []
 var state = "unknown"
 var updatedAt: Date?
 var progress = ""
 var completionID: String?
}

// Each instance is confined to its monitor's serial queue (or one test thread).
final class CodexConversationReader: @unchecked Sendable {
 private(set) var snapshot = CodexConversationSnapshot()
 private var offset: UInt64 = 0
 private var fileIdentity: UInt64?
 private var pending = Data()
 private var droppingLine = false
 private var messageID = 0
 private var turnID: String?
 private let limit = 1_048_576
 private let dateParser: ISO8601DateFormatter = {
  let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f
 }()

 // Bounded, read-only tail. Never deserialize the entire conversation or retain
 // tool payloads, internal reasoning, or a second transcript copy.
 func poll(_ url: URL) throws -> CodexConversationSnapshot {
  let values=try FileManager.default.attributesOfItem(atPath:url.path)
  guard values[.type] as? FileAttributeType == .typeRegular else {throw CocoaError(.fileReadUnsupportedScheme)}
  let size=(values[.size] as? NSNumber)?.uint64Value ?? 0
  let identity=(values[.systemFileNumber] as? NSNumber)?.uint64Value
  if identity != fileIdentity || size<offset {
   snapshot=CodexConversationSnapshot();offset=0;pending.removeAll();droppingLine=false;turnID=nil;fileIdentity=identity
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
 private func consume(_ line:Data) {
  guard line.count<=limit,let root=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any],let payload=root["payload"] as? [String:Any] else{return}
  let type=root["type"] as? String,kind=payload["type"] as? String
  let date=(root["timestamp"] as? String).flatMap{dateParser.date(from:$0) ?? ISO8601DateFormatter().date(from:$0)}
  if snapshot.state=="working",let date {snapshot.updatedAt=date}
  if type=="event_msg" {
   if kind=="task_started" {turnID=payload["turn_id"] as? String;snapshot.state="working";snapshot.updatedAt=date;snapshot.progress=""}
   else if ["task_complete","turn_aborted"].contains(kind ?? ""),
           turnID==nil || payload["turn_id"] as? String == turnID {
    snapshot.state=kind=="task_complete" ? "completed":"cancelled";snapshot.updatedAt=date
    if kind=="task_complete" {snapshot.completionID=turnID ?? (root["timestamp"] as? String)}
   }
   return
  }
  guard type=="response_item",kind=="message",let role=payload["role"] as? String,["user","assistant"].contains(role),
        payload["channel"] as? String != "analysis",payload["phase"] as? String != "analysis",let content=payload["content"] as? [[String:Any]] else{return}
  let text=content.compactMap { item -> String? in
   guard let type=item["type"] as? String,["input_text","output_text"].contains(type) else{return nil}
   return item["text"] as? String
  }.joined(separator:"\n")
  guard !text.isEmpty else{return}
  if role=="assistant" {
   snapshot.progress=String(text.prefix(600))
   // A visible progress event is evidence of activity even if the bounded
   // initial tail omitted this turn's start. Final/user text alone is not.
   if (payload["channel"] as? String == "commentary" || payload["phase"] as? String == "commentary"),snapshot.state != "working" {
    snapshot.state="working";turnID=nil
   }
  }
  messageID+=1;snapshot.messages.append(.init(id:messageID,role:role,text:String(text.prefix(12000))))
  snapshot.messages=Array(snapshot.messages.suffix(40));snapshot.updatedAt=date
 }
}

enum CodexThreadLink {
 static func url(forPath path:String)->URL? {
  let file=URL(fileURLWithPath:path)
  guard file.pathExtension=="jsonl",file.lastPathComponent.hasPrefix("rollout-"),
        let id=UUID(uuidString:String(file.deletingPathExtension().lastPathComponent.suffix(36))) else{return nil}
  return URL(string:"codex://threads/"+id.uuidString.lowercased())
 }
}
