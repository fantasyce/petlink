import Foundation

@main struct ClaudeHookSettingsTests {
 static func main()throws {
  let original:[String:Any]=["permissions":["allow":["Read"]],"hooks":["Stop":[["matcher":"","hooks":[["type":"command","command":"existing-hook"]]]]]]
  let unrelated:[String:Any]=["hooks":["Stop":[["matcher":"","hooks":[["type":"command","command":"echo PetLinkAgentEvent is mentioned by an unrelated hook"],["type":"command","command":"/other/PetLinkAgentEvent deepseek working"]]]]]]
  precondition(NSDictionary(dictionary:ClaudeHookSettings.removing(from:unrelated)).isEqual(to:unrelated),"migration preserves unrelated commands and providers")
  var installed=original, hooks=original["hooks"] as! [String:Any]
  for (event,state) in [("SessionStart","session_start"),("UserPromptSubmit","working"),("PreToolUse","tool_start"),("PermissionRequest","permission_request"),("Stop","completed"),("PostToolUseFailure","failed"),("SessionEnd","disconnected")] {
   var entries=hooks[event] as? [[String:Any]] ?? []
   entries.append(["matcher":"","hooks":[["type":"command","command":"\"/Applications/PetLink.app/Contents/MacOS/PetLinkAgentEvent\" claude "+state]]]);hooks[event]=entries
  }
  installed["hooks"]=hooks
  precondition(NSDictionary(dictionary:ClaudeHookSettings.removing(from:installed)).isEqual(to:original),"only the seven owned hooks are removed")
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let file=root.appendingPathComponent("settings.json"),bytes=try JSONSerialization.data(withJSONObject:installed)
  try bytes.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
  let changed=try ClaudeHookSettings.removeLegacyHooks(at:file);precondition(changed)
  let removed=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
  precondition(NSDictionary(dictionary:removed).isEqual(to:original))
  let backups=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(".petlink-legacy-hooks-")}
  precondition(backups.count==1);let backupBytes=try Data(contentsOf:backups[0]);precondition(backupBytes==bytes,"exact private recovery backup")
  for url in [file,backups[0]] {let permissions=try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as! NSNumber;precondition(permissions.intValue==0o600)}
  let twice=try ClaudeHookSettings.removeLegacyHooks(at:file);precondition(!twice,"migration is idempotent")
  let missing=try ClaudeHookSettings.removeLegacyHooks(at:root.appendingPathComponent("missing/settings.json"));precondition(!missing,"do not create config on an unused installation")
  let malformed=root.appendingPathComponent("malformed.json");try Data("broken".utf8).write(to:malformed)
  do {_ = try ClaudeHookSettings.removeLegacyHooks(at:malformed);preconditionFailure("invalid user settings must remain untouched")}catch{}
  let badBytes=try Data(contentsOf:malformed);precondition(badBytes==Data("broken".utf8))
  print("Legacy Claude hook migration: seven owned entries / unrelated config / backup / permissions / idempotence PASS")
 }
}
