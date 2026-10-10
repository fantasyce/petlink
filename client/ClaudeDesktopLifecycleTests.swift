import Foundation

@main struct ClaudeDesktopLifecycleTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:root)}
  let file=root.appendingPathComponent("11111111-2222-4333-8444-555555555555.jsonl")
  func append(_ value:[String:Any]) throws {
   let data=try JSONSerialization.data(withJSONObject:value)+Data([10])
   if FileManager.default.fileExists(atPath:file.path){let h=try FileHandle(forWritingTo:file);defer{try? h.close()};try h.seekToEnd();try h.write(contentsOf:data)}else{try data.write(to:file)}
  }
  func check(_ value:Bool,_ message:String){if !value{fputs(message+"\n",stderr);exit(1)}}
  let reader=ClaudeConversationReader(metadataOnly:true)
  try append(["type":"user","timestamp":"2026-10-03T04:00:00Z","message":["content":"Desktop task"]])
  var snapshot=try reader.poll(file)
  check(snapshot.state=="working","Desktop SDK without agents status must still expose a live turn")
  check(snapshot.messages.isEmpty && snapshot.progress.isEmpty,"Metadata reader must not retain conversation text")
  try append(["type":"assistant","isSidechain":true,"message":["content":[["type":"text","text":"Child result"]],"stop_reason":"end_turn"]])
  snapshot=try reader.poll(file);check(snapshot.state=="working","A subagent ending must not end the parent turn")
  try append(["type":"assistant","message":["content":[["type":"thinking","thinking":"private"]],"stop_reason":"end_turn"]])
  snapshot=try reader.poll(file);check(snapshot.state=="working","A streamed thinking block must not retire the bubble before the final text")
  try append(["type":"assistant","uuid":"finished-turn","timestamp":"2026-10-03T04:01:00Z","message":["content":[["type":"text","text":"Finished"]],"stop_reason":"end_turn"]])
  snapshot=try reader.poll(file)
  check(snapshot.state=="completed" && snapshot.completionID=="finished-turn","Final desktop answer must retire the live turn")
  check(snapshot.messages.isEmpty && snapshot.progress.isEmpty,"Completed text must also stay outside PetLink")
  try append(["type":"custom-title","customTitle":"Desktop title"])
  snapshot=try reader.poll(file);check(snapshot.state=="completed","Renaming an idle session must not create a bubble")
  try append(["type":"user","message":["content":"Second turn"]]);snapshot=try reader.poll(file)
  check(snapshot.state=="working" && snapshot.completionID==nil,"A new desktop turn must be captured again")
  try append(["type":"user","message":["content":[["type":"text","text":"[Request interrupted by user for tool use]"]]]]);snapshot=try reader.poll(file)
  check(snapshot.state=="cancelled","Desktop Stop must retire an interrupted tool turn")
  try append(["type":"user","message":["content":"Next task"]]);snapshot=try reader.poll(file)
  check(snapshot.state=="working","A stopped desktop session can execute a later turn")
  try append(["type":"user","message":["content":"[Request interrupted by user]"]]);snapshot=try reader.poll(file)
  check(snapshot.state=="cancelled","Desktop Stop must also retire a turn without tool use")
  try append(["type":"user","message":["content":"Explain the marker [Request interrupted by user]"]]);snapshot=try reader.poll(file)
  check(snapshot.state=="working","Mentioning an interruption marker must not cancel an ordinary prompt")
  print("Claude Desktop lifecycle and metadata privacy PASS")
 }
}
