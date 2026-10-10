import AppKit
import Foundation

@main struct ConversationFeedbackTests {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  setenv("CODEX_HOME",root.path,1)
  let name="com.fantasyce.petlink.tests.feedback-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
  defaults.set(false,forKey:"codex-auto-active");defer{defaults.removePersistentDomain(forName:name)}
  let pasteboard=NSPasteboard(name:NSPasteboard.Name(name));defer{pasteboard.releaseGlobally()}
  var opened:[URL]=[],canOpen=true
  let monitor=CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:root,listing:{Thread.sleep(forTimeInterval:0.2);return []},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]}),pasteboard:pasteboard,desktopOpener:{opened.append($0);return canOpen})
  func check(_ value:Bool,_ message:String)throws{if !value{fputs(message+"\n",stderr);exit(1)}}
  let dsh=root.appendingPathComponent("home/storages/session_projcache/sessions/session-feedback-1.json").path
  pasteboard.setString("preserve clipboard",forType:.string)
  monitor.openInCodex(dsh)
  try await Task.sleep(nanoseconds:50_000_000)
  try check(opened.map(\.absoluteString)==["dsh://open"],"Desktop must receive only its supported main-window URL")
  try check(pasteboard.string(forType:.string)=="preserve clipboard" && monitor.openNotice.isEmpty,"Opening the DSH main window must not look up session metadata, require extra authorization or overwrite the clipboard")
  canOpen=false;monitor.openInCodex(dsh)
  try check(monitor.openNotice.contains("DeepSeek Harness"),"a failed native opening must give actionable feedback")
  let desktop=root.appendingPathComponent("Claude/claude-code-sessions/account/org/local_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.json").path
  canOpen=true;monitor.openInCodex(desktop)
  try check(opened.last?.absoluteString=="claude://claude.ai/epitaxy/local_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","Desktop bubbles must send the exact local conversation route")
  try check(pasteboard.string(forType:.string)=="preserve clipboard" && monitor.openNotice.isEmpty,"Desktop jump must preserve the user's clipboard")
  canOpen=false;monitor.openInCodex(desktop)
  try check(monitor.openNotice.contains("Claude Desktop"),"Failed Desktop navigation must show its own recovery feedback")
  let claude=root.appendingPathComponent("projects/example/11111111-1111-4111-8111-111111111111.jsonl").path
  monitor.openInCodex(claude)
  try check(monitor.openNotice=="会话命令已复制","Claude still copies its supported resume command")
  let first=monitor.openNotice
  try check(pasteboard.string(forType:.string)=="claude --resume 11111111-1111-4111-8111-111111111111","Claude clipboard behavior remains correct")
  try await Task.sleep(nanoseconds:3_100_000_000)
  try check(monitor.openNotice.isEmpty,"successful copy feedback must disappear automatically")
  monitor.openInCodex(claude);try await Task.sleep(nanoseconds:1_400_000_000)
  monitor.openInCodex(claude)
  try check(monitor.openNotice==first,"repeat copy feedback stays consistent")
  try await Task.sleep(nanoseconds:1_400_000_000)
  try check(!monitor.openNotice.isEmpty,"an earlier copy timeout cannot clear newer feedback")
  try await Task.sleep(nanoseconds:1_300_000_000)
  try check(monitor.openNotice.isEmpty,"the latest copy feedback also expires")
  monitor.automaticEnabled=true;monitor.refreshConnections()
  try check(monitor.connectionsChecking,"a manual retry must publish its in-flight state immediately")
  for _ in 0..<100 {if !monitor.connectionsChecking{break};try await Task.sleep(nanoseconds:50_000_000)}
  try check(!monitor.connectionsChecking,"a finished compatibility read must clear the in-flight state")
  monitor.refreshConnections();try check(monitor.connectionsChecking,"retry can be started again")
  monitor.automaticEnabled=false;try check(!monitor.connectionsChecking,"turning tracking off must clear a pending retry")
  print("Conversation feedback: Desktop native open without clipboard, Claude command copy, expiry and overlapping actions PASS")
 }
}
