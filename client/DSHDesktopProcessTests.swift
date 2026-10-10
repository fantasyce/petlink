import Foundation
import Darwin

@main struct DSHDesktopProcessTests {
 static func main()throws {
  if CommandLine.arguments.contains("--expose-internals") {
   let args=CommandLine.arguments
   let fd=Darwin.open(args[4],args[5]=="writer" ? O_RDWR:O_RDONLY)
   guard fd>=0 else{exit(2)};defer{Darwin.close(fd)}
   try Data(String(getpid()).utf8).write(to:URL(fileURLWithPath:args[6]))
   while !FileManager.default.fileExists(atPath:args[7]) {Thread.sleep(forTimeInterval:0.01)}
   return
  }
  if CommandLine.arguments[1]=="--desktop-parent" {
   let args=CommandLine.arguments,p=Process()
   p.executableURL=URL(fileURLWithPath:args[0]);p.arguments=["--expose-internals",args[2]+"/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js",args[2]]+Array(args[3...])
   try p.run();p.waitUntilExit();exit(p.terminationStatus)
  }
  let fm=FileManager.default,requested=URL(fileURLWithPath:CommandLine.arguments[1])
  try fm.createDirectory(at:requested,withIntermediateDirectories:true)
  let root=requested.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString),app=root.appendingPathComponent("DeepSeek Harness.app")
  defer{try? fm.removeItem(at:root)}
  let executable=app.appendingPathComponent("Contents/MacOS/DeepSeek Harness"),runtime=app.appendingPathComponent("Contents/Resources/app.asar/dsh").path
  try fm.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
  try fm.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[0]),to:executable)
  let info=["CFBundleIdentifier":"com.deepseek.dsh","CFBundleExecutable":"DeepSeek Harness","CFBundleShortVersionString":"0.2.0-rc.2"]
  try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
  let path=root.appendingPathComponent("home/sessions/project/session-native-test/session.lock")
  try fm.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try Data().write(to:path)
  let inspector=DSHDesktopProcessInspector(application:{app})
  precondition(!DSHDesktopProcessInspector.isHost(arguments:["node","/old/node_modules/@deepseek-ai/dsh/lib/bin.js"],runtime:runtime),"legacy CLI cannot authorize Desktop reads")
  precondition(!DSHDesktopProcessInspector.isHost(arguments:[runtime+"/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js","/other/runtime"],runtime:runtime),"a different runtime cannot qualify")
  func owned()->[DSHDesktopSessionLease]{inspector.scan().filter{DSHDesktopApplication.canonicalPath($0.lockPath)==DSHDesktopApplication.canonicalPath(path.path)}}
  func start(_ mode:String)throws->(Process,URL,Int32) {
   let marker=root.appendingPathComponent(UUID().uuidString),stop=root.appendingPathComponent(UUID().uuidString),p=Process()
   p.executableURL=executable;p.arguments=["--desktop-parent",runtime,path.path,mode,marker.path,stop.path]
   p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run()
   for _ in 0..<200 where !fm.fileExists(atPath:marker.path){Thread.sleep(forTimeInterval:0.01)}
   precondition(fm.fileExists(atPath:marker.path),"native Desktop Host fixture did not start")
   let pid=Int32(try String(contentsOf:marker,encoding:.utf8))!
   return (p,stop,pid)
  }
  func stop(_ value:(Process,URL,Int32)) {try? Data().write(to:value.1);value.0.waitUntilExit()}
  let reader=try start("reader")
  precondition(owned().isEmpty && inspector.hostRunning,"Desktop history readers prove Host presence but not activity ownership");stop(reader)
  let writer=try start("writer")
  precondition(owned().count==1 && owned()[0].processIdentity.hasPrefix(String(writer.2)+":"),"Desktop ownership binds child PID/start time and main parent")
  try fm.removeItem(at:path);try Data().write(to:path)
  precondition(owned().isEmpty,"a recreated lock cannot inherit an old inode");stop(writer)
  precondition(owned().isEmpty && !inspector.hostRunning,"exited Desktop Host cannot keep activity alive")
  let replacement=try start("writer")
  precondition(owned().count==1,"new Host is captured after exit")
  let startTime=Date();for _ in 0..<100{_=inspector.scan()}
  print("Desktop native ownership, legacy CLI exclusion, reader/inode/exit/restart PASS; 100 scans: \(Date().timeIntervalSince(startTime))s")
  stop(replacement)
 }
}
