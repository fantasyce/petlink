import Foundation

@main struct AgentVersionMonitorTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let command=root.appendingPathComponent("codex-version"),link=root.appendingPathComponent("codex-link"),count=root.appendingPathComponent("launch-count")
  func script(_ version:String,status:Int=0)throws {
   let text="#!/bin/sh\n[ \"$1\" = --version ] || exit 9\n[ \"$PWD\" = / ] || exit 8\nprintf x >> '\(count.path)'\nprintf '%s\\n' '\(version)'\nexit \(status)\n"
   try Data(text.utf8).write(to:command,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:command.path)
  }
  try script("0.159.2");try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:command.path)
  var resolved:[String]=[]
  let monitor=AgentVersionMonitor(resolve:{resolved.append($0);return $0=="codex" ? link.path:nil},desktopApplication:{nil})
  precondition(monitor.scan()["codex"]?.version=="0.159.2","installed version must be read from the real executable")
  for _ in 0..<25{precondition(monitor.scan()["codex"]?.version=="0.159.2")}
  precondition(!resolved.contains("dsh"),"Desktop integration must never resolve or launch legacy dsh CLI")
  let count1=try Data(contentsOf:count).count;precondition(count1==1,"unchanged executables must not launch repeated version commands")
  try script("0.200.0")
  let upgraded=monitor.scan()["codex"]!
  precondition(upgraded.version=="0.200.0" && upgraded.issue.isEmpty,"a changed version must refresh without declaring incompatibility")
  let count2=try Data(contentsOf:count).count;precondition(count2==2,"replacement behind a symlink must be detected once")
  _=monitor.scan(force:true);let count3=try Data(contentsOf:count).count;precondition(count3==3,"manual retry must bypass an unchanged executable cache")
  try script("",status:1)
  precondition(!monitor.scan()["codex"]!.issue.isEmpty,"version-command failure must be distinguished from absence")
  try FileManager.default.removeItem(at:link)
  precondition(monitor.scan()["codex"]?.version=="未安装","executable removal must clear a cached version")
  try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:command.path);try script("0.201.0")
  precondition(monitor.scan()["codex"]?.version=="0.201.0","reinstallation must recover without restarting PetLink")
  let app=root.appendingPathComponent("DeepSeek Harness.app"),info=app.appendingPathComponent("Contents/Info.plist"),desktop=app.appendingPathComponent("Contents/MacOS/DeepSeek Harness")
  try FileManager.default.createDirectory(at:desktop.deletingLastPathComponent(),withIntermediateDirectories:true)
  try Data("#!/bin/sh\nexit 99\n".utf8).write(to:desktop);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:desktop.path)
  func bundle(_ version:String,_ id:String="com.deepseek.dsh")throws {
   let values=["CFBundleIdentifier":id,"CFBundleExecutable":"DeepSeek Harness","CFBundleShortVersionString":version]
   try PropertyListSerialization.data(fromPropertyList:values,format:.xml,options:0).write(to:info,options:.atomic)
  }
  try bundle("0.2.0-rc.2")
  let native=AgentVersionMonitor(resolve:{_ in nil},desktopApplication:{app})
  precondition(native.scan()["deepseek"]?.version=="0.2.0-rc.2","Desktop version comes from its bundle without executing it")
  try bundle("0.3.0");precondition(native.scan()["deepseek"]?.version=="0.3.0","replacement Info.plist must not be hidden by Bundle caching")
  try bundle("0.3.0","unrelated.app");precondition(native.scan()["deepseek"]?.version=="未安装","unrelated bundles must not qualify")
  try bundle("0.3.0");try FileManager.default.removeItem(at:desktop)
  precondition(native.scan()["deepseek"]?.version=="未安装","a removed Desktop executable clears its version")
  print("Agent versions: native fingerprints, unchanged-command reuse, symlink upgrade, forced retry, failure, removal and reinstall PASS")
 }
}
