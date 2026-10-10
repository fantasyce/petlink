import Foundation
import Darwin

@main struct AgentExecutableQuarantineTests {
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),bin=root.appendingPathComponent(".local/bin"),fake=bin.appendingPathComponent("codex")
  try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
  try Data("#!/bin/sh\nexit 99\n".utf8).write(to:fake)
  try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:fake.path)
  let mark=Array("0083;65000000;PetLink-QA;task-only".utf8)
  precondition(mark.withUnsafeBytes{setxattr(fake.path,"com.apple.quarantine",$0.baseAddress,mark.count,0,0)}==0)
  let resolved=try? AgentExecutable.resolve("codex",environment:["PATH":"/usr/bin:/bin"],home:root.path)
  precondition(resolved != fake.path,"automatic discovery must not choose a quarantined executable rejected by macOS")
  print("Agent discovery: quarantined, system-rejected executables are assessed without launching them PASS")
 }
}
