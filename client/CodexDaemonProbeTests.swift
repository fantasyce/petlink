import Foundation

@main struct CodexDaemonProbeTests {
 static func main()throws {
  precondition(!CodexDaemonProbe.isUserSource(["subAgent":["thread_spawn":["parent_thread_id":"qa-parent"]]]))
  precondition(!CodexDaemonProbe.isUserSource(["subagent":["thread_spawn":["parent_thread_id":"qa-parent"]]]))
  precondition(CodexDaemonProbe.isUserSource("vscode") && CodexDaemonProbe.isUserSource("cli"))
  print("Codex daemon source filter PASS")
  guard CommandLine.arguments.count>=2 else{print("Codex daemon probe skipped");return};let selected=CommandLine.arguments.count>2 ? CommandLine.arguments[2]:nil;let result=try CodexDaemonProbe.run(socketPath:CommandLine.arguments[1],selected:selected);if selected == nil{precondition(result.event==nil)};print("Codex daemon read-only probe passed; loaded=\(result.threads.joined(separator:",")); event=\(result.event ?? "none")")}
}
