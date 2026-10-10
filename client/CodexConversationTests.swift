import Foundation

@main struct CodexConversationTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let file=root.appendingPathComponent("conversation.jsonl")
  func line(_ type:String,_ payload:[String:Any])->Data {
   var d=try! JSONSerialization.data(withJSONObject:["type":type,"timestamp":"2026-09-29T15:22:52.458Z","payload":payload]);d.append(10);return d
  }
  func append(_ d:Data)throws{let f=try FileHandle(forWritingTo:file);defer{try? f.close()};try f.seekToEnd();try f.write(contentsOf:d)}
  let start=line("event_msg",["type":"task_started","turn_id":"one"])
  try start.write(to:file)
  let reader=CodexConversationReader()
  precondition(try! reader.poll(file).state=="working","start event must update state")
  try append(line("response_item",["type":"message","role":"user","content":[["type":"input_text","text":"你好"]]]))
  try append(line("response_item",["type":"message","role":"assistant","channel":"analysis","content":[["type":"output_text","text":"PRIVATE_REASONING"]]]))
  try append(line("response_item",["type":"function_call_output","output":"PRIVATE_TOOL_OUTPUT"]))
  try append(line("response_item",["type":"message","role":"system","content":[["type":"input_text","text":"PRIVATE_SYSTEM"]]]))
  let answer=line("response_item",["type":"message","role":"assistant","channel":"final","content":[["type":"output_text","text":"你好，小面包"]]])
  try append(answer.dropLast(3))
  var snap=try reader.poll(file)
  precondition(snap.messages.map(\.text)==["你好"],"filter private channels and incomplete line")
  try append(answer.suffix(3));snap=try reader.poll(file)
  precondition(snap.messages.map(\.text)==["你好","你好，小面包"],"UTF-8 split reassembled")
  let unchanged=try reader.poll(file)
  precondition(unchanged==snap,"poll must not duplicate messages")
  try append(line("event_msg",["type":"task_complete","turn_id":"one"]))
  precondition(try! reader.poll(file).state=="completed","completion event")
  try append(line("event_msg",["type":"task_started","turn_id":"two"]))
  try append(line("event_msg",["type":"task_complete","turn_id":"one"]))
  precondition(try! reader.poll(file).state=="working","old turn completion must not end new turn")
  try append(line("event_msg",["type":"turn_aborted","turn_id":"two"]))
  precondition(try! reader.poll(file).state=="cancelled","abort is not success")
  try Data("{bad}\n".utf8).write(to:file)
  precondition(try! reader.poll(file).messages.isEmpty,"truncation clears old content")
  for i in 0..<80 {try append(line("response_item",["type":"message","role":"assistant","content":[["type":"output_text","text":"message \(i)"]]]))}
  snap=try reader.poll(file)
  precondition(snap.messages.count==40 && snap.messages.last?.text=="message 79","bounded recent messages")
  try Data("{bad}\n".utf8).write(to:file)
  _ = try reader.poll(file)
  try append(line("response_item",["type":"message","role":"assistant","channel":"commentary","content":[["type":"output_text","text":"正在执行本地验收"]]]))
  precondition(try! reader.poll(file).state=="working","public progress establishes activity even when turn start lies outside the bounded tail")
  try Data("{bad}\n".utf8).write(to:file);_ = try reader.poll(file)
  try append(line("response_item",["type":"message","role":"assistant","phase":"commentary","content":[["type":"output_text","text":"桌面版公开进展"]]]))
  precondition(try! reader.poll(file).state=="working","desktop phase field supplies public progress")
  try Data("{bad}\n".utf8).write(to:file);_ = try reader.poll(file)
  try append(line("event_msg",["type":"task_started","turn_id":"heartbeat"]))
  var heartbeat=try! JSONSerialization.data(withJSONObject:["type":"response_item","timestamp":"2026-09-29T15:23:52.458Z","payload":["type":"function_call_output","output":"PRIVATE_TOOL_OUTPUT"]]);heartbeat.append(10)
  try append(heartbeat)
  precondition(try! reader.poll(file).updatedAt==ISO8601DateFormatter().date(from:"2026-09-29T15:23:52Z")!.addingTimeInterval(0.458),"tool activity must keep a running turn fresh without exposing tool output")
  precondition(try! reader.poll(file).messages.isEmpty,"heartbeat must not expose tool output")
  print("Codex local conversation filtering / partial UTF8 / incremental / lifecycle / truncate / retention PASS")
 }
}
