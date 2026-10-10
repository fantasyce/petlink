import Foundation
import Darwin

enum ClaudeHookSettings {
 // Migration only. New versions never install Claude hooks.
 private static func isLegacy(_ hook:[String:Any])->Bool {
  guard hook["type"] as? String=="command",let command=hook["command"] as? String else{return false}
  let pattern=#"^(?:"[^"\n]*/PetLinkAgentEvent"|[^\s"']*/PetLinkAgentEvent)\s+claude\s+(?:session_start|working|tool_start|permission_request|completed|failed|disconnected)\s*$"#
  return command.range(of:pattern,options:.regularExpression) != nil
 }
 static func removing(from original:[String:Any])->[String:Any] {
  var root=original;guard var hooks=root["hooks"] as? [String:Any] else{return root}
  for name in Array(hooks.keys) {
   guard let entries=hooks[name] as? [[String:Any]] else{continue}
   let kept=entries.compactMap{entry->[String:Any]? in
    guard let commands=entry["hooks"] as? [[String:Any]] else{return entry}
    let remaining=commands.filter{!isLegacy($0)}
    guard remaining.count != commands.count else{return entry}
    guard !remaining.isEmpty else{return nil}
    var next=entry;next["hooks"]=remaining;return next
   }
   if kept.isEmpty{hooks.removeValue(forKey:name)}else{hooks[name]=kept}
  }
  root["hooks"]=hooks;return root
 }
 @discardableResult static func removeLegacyHooks(at target:URL)throws->Bool {
  let url=target.resolvingSymlinksInPath()
  guard FileManager.default.fileExists(atPath:url.path) else{return false}
  let data=try Data(contentsOf:url)
  guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw CocoaError(.fileReadCorruptFile)}
  let next=removing(from:root)
  guard !NSDictionary(dictionary:root).isEqual(to:next) else{return false}
  let permissions=(try FileManager.default.attributesOfItem(atPath:url.path))[.posixPermissions]
  let backup=url.deletingLastPathComponent().appendingPathComponent(".petlink-legacy-hooks-"+UUID().uuidString+".json")
  let descriptor=Darwin.open(backup.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
  guard descriptor>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
  let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
  try handle.write(contentsOf:data);try handle.close()
  guard try Data(contentsOf:url)==data else{throw CocoaError(.fileWriteFileExists)}
  try JSONSerialization.data(withJSONObject:next,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
  if let permissions {try FileManager.default.setAttributes([.posixPermissions:permissions],ofItemAtPath:url.path)}
  return true
 }
}
