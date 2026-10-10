import AppKit
import SwiftUI

@main struct VisitorChatBubbleTests {
 @MainActor static func main()async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  setenv("CODEX_HOME",root.path,1)
  let suite="com.fantasyce.petlink.visitor-tests."+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!;defaults.set(false,forKey:"codex-auto-active")
  defer{defaults.removePersistentDomain(forName:suite)}
  let monitor=CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:root,listing:{[]},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]}))
  let windows=PetWindows(profile:"visitor-test",defaults:defaults,conversation:monitor)
  let own=Pet(owner:"host",name:"主人",location:"host",target:"",phase:"home",revision:1,style:6,wave:0)
  let guest=Pet(owner:"guest",name:"来访好友",location:"host",target:"host",phase:"visit",revision:1,style:9,wave:0)
  var opened=""
  windows.openVisitorChat={opened=$0}
  windows.update([own,guest],selfID:"host")
  let request=VisitorChatBubble(taskID:"one",ownerID:"guest",name:"来访好友",message:"等待好友同意",isAnswer:false)
  windows.setVisitorChats([request])
  func bubble()->NSWindow?{NSApplication.shared.windows.first{$0.title=="PetLink 来访好友的聊天气泡" && $0.isVisible}}
  precondition(bubble() != nil,"a visitor's chat must appear beside the visitor, even when local tracking is off")
  let first=bubble()!
  precondition(first.contentView?.acceptsFirstMouse(for:nil)==true,"visitor chat must open on the first click, including an inactive bubble window")
  precondition(PetScreen.connected.contains{$0.bounds.contains(first.frame)},"visitor bubble stays in a visible screen")
  windows.setVisitorChats([VisitorChatBubble(taskID:"one",ownerID:"guest",name:"来访好友",message:"简短回答",isAnswer:true)])
  precondition(bubble() === first,"updating an answer must reuse the visitor panel")
  windows.activateVisitorChat("guest")
  precondition(opened=="guest","visitor bubble opens that friend's PetLink chat")
  monitor.bubblesEnabled=false
  precondition(bubble()==nil && windows.visibleOwners==["host","guest"],"bubble switch hides visitor bubbles without hiding pets")
  monitor.bubblesEnabled=true
  precondition(bubble() != nil,"bubble switch restores visitor chat")
  windows.setHidden(true);precondition(bubble()==nil)
  windows.setHidden(false);precondition(bubble() != nil)
  windows.hide("guest");precondition(bubble()==nil,"revoked display lease hides the visitor bubble immediately")
  windows.setHidden(true);windows.setHidden(false);precondition(bubble()==nil,"restoring pets must not resurrect a revoked visit")
  windows.update([own],selfID:"host");precondition(bubble()==nil)
  windows.setVisitorChats([]);windows.update([own,guest],selfID:"host")
  precondition(bubble()==nil,"a later visit must not restore old private chat previews")
  windows.setVisitorChats([request]);windows.hideAll();precondition(bubble()==nil)
  windows.setVisitorChats([request]);precondition(bubble()==nil,"late chat callbacks cannot show a disconnected visitor")
  windows.conversation.stop();windows.hideAll()
  print("Visitor bubble: status/answer, click target, tracking independence, bounds, hide/restore and visit/disconnect lifecycle PASS")
 }
}
