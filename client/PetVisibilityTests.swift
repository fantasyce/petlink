import AppKit
import SwiftUI
final class MenuBlankView:NSView {
 var clicks=0
 override func mouseDown(with event:NSEvent){clicks+=1}
}
@main struct PetVisibilityTests {
 @MainActor static func main()async throws{
  let app=NSApplication.shared
  app.setActivationPolicy(.accessory)
  app.activate(ignoringOtherApps:true)
  setenv("CODEX_HOME",URL(fileURLWithPath:CommandLine.arguments[1]).path,1)
  let suite="com.fantasyce.petlink.visibility-tests."+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!;defaults.set(false,forKey:"codex-auto-active");defer{defaults.removePersistentDomain(forName:suite)}
  PencilFont.register(resources:URL(fileURLWithPath:"client/Resources",isDirectory:true))
  let monitor=CodexConversationMonitor(defaults:defaults,dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]}))
  precondition(monitor.bubblesEnabled,"bubbles default to enabled")
  monitor.bubblesEnabled=false
  precondition(!CodexConversationMonitor(defaults:defaults,dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]})).bubblesEnabled,"the bubble preference survives restart")
  monitor.bubblesEnabled=true
  let menu=NSHostingController(rootView:PencilRoot(preferences:PencilPreferences(profile:"visibility-test",defaults:defaults)){PetQuickMenu(conversation:monitor,outfit:{},hide:{})})
  let menuSize=menu.view.fittingSize
  precondition((65...110).contains(menuSize.width),"right-click menu must fit its short actions without the old wide blank area")
  precondition((110...155).contains(menuSize.height),"outfit, bubble switch and hide must fit without clipping")
  print("Pet menu natural fitting size: \(menuSize.width) × \(menuSize.height)")
  let pet=Pet(owner:"task-own",name:"QA",location:"task-own",target:"",phase:"home",revision:0,style:0,wave:0)
  let windows=PetWindows(profile:"visibility-test",defaults:defaults,conversation:CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:URL(fileURLWithPath:CommandLine.arguments[1]),listing:{[]},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]})))
  windows.update([pet],selfID:pet.owner);precondition(windows.visibleOwners==[pet.owner])
  let panel=app.windows.first{$0.title=="PetLink 桌宠 task-own"}!
  let fixture=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("rollout-11111111-2222-3333-4444-555555555551.jsonl")
  try FileManager.default.createDirectory(at:fixture.deletingLastPathComponent(),withIntermediateDirectories:true)
  var content=try JSONSerialization.data(withJSONObject:["timestamp":ISO8601DateFormatter().string(from:Date()),"type":"event_msg","payload":["type":"task_started","turn_id":"visibility-qa"]]);content.append(10);try content.write(to:fixture)
  windows.conversation.automaticEnabled=true;windows.conversation.select(fixture)
  for _ in 0..<300 {windows.conversation.refresh();if !windows.conversation.activeSessions.isEmpty{break};try? await Task.sleep(nanoseconds:10_000_000)}
  precondition(app.windows.contains{$0.title=="PetLink 会话气泡" && $0.isVisible},"an active session shows its bubble panel")
  windows.conversation.bubblesEnabled=false
  precondition(!app.windows.contains{$0.title=="PetLink 会话气泡" && $0.isVisible} && windows.visibleOwners==[pet.owner],"hiding bubbles keeps the desktop pet visible")
  windows.conversation.bubblesEnabled=true
  precondition(app.windows.contains{$0.title=="PetLink 会话气泡" && $0.isVisible},"turning bubbles back on restores the active panel")
  windows.conversation.stop()
  // NSPopover closes asynchronously. A rapid reopen must start after its
  // didClose boundary, rather than racing a previous closing animation.
  var menuClosing=false
  let notifications=NotificationCenter.default
  let willClose=notifications.addObserver(forName:NSPopover.willCloseNotification,object:nil,queue:.main){_ in menuClosing=true}
  let didClose=notifications.addObserver(forName:NSPopover.didCloseNotification,object:nil,queue:.main){_ in menuClosing=false}
  defer{notifications.removeObserver(willClose);notifications.removeObserver(didClose)}
  func settle(){RunLoop.main.run(until:Date().addingTimeInterval(0.35))}
  func openMenu()->NSWindow {
   let deadline=Date().addingTimeInterval(3)
   while menuClosing && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
   precondition(!menuClosing,"the preceding menu must finish closing before reopening")
   let existing=Set(app.windows.filter(\.isVisible).map(ObjectIdentifier.init))
   let right=NSEvent.mouseEvent(with:.rightMouseDown,location:NSPoint(x:80,y:80),modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
   app.sendEvent(right);settle()
   return app.windows.first{$0.isVisible && !existing.contains(ObjectIdentifier($0))}!
  }
  func mouseDown(in target:NSWindow,at point:NSPoint){
   let event=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:target.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
   app.sendEvent(event);settle()
  }
  let popup=openMenu()
  mouseDown(in:popup,at:NSPoint(x:5,y:5))
  precondition(popup.isVisible,"clicking inside the menu must leave its actions usable")
  mouseDown(in:panel,at:NSPoint(x:5,y:5))
  precondition(!popup.isVisible,"clicking blank space outside the menu must dismiss it on a nonactivating pet panel")
  let blankWindow=NSWindow(contentRect:NSRect(x:50,y:50,width:100,height:100),styleMask:.borderless,backing:.buffered,defer:false)
  let blank=MenuBlankView(frame:NSRect(x:0,y:0,width:100,height:100));blankWindow.contentView=blank;blankWindow.orderFrontRegardless()
  for attempt in 1...3 {
   let reopened=openMenu()
   mouseDown(in:blankWindow,at:NSPoint(x:20,y:20))
   precondition(!reopened.isVisible,"outside clicks must keep dismissing the menu after reopening")
   precondition(blank.clicks==attempt,"dismissal must pass the outside click to its original window")
  }
  blankWindow.orderOut(nil)
  let escaped=openMenu()
  let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
  app.sendEvent(escape);settle();precondition(!escaped.isVisible,"Escape dismisses the menu")
  let deactivated=openMenu()
  NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:app)
  settle();precondition(!deactivated.isVisible,"switching away from PetLink dismisses the menu")
  windows.setHidden(true);precondition(windows.visibleOwners.isEmpty)
  windows.update([pet],selfID:pet.owner);precondition(windows.visibleOwners.isEmpty,"refresh cannot undo manual hide")
  precondition(PetWindows(profile:"visibility-test",defaults:defaults,conversation:CodexConversationMonitor(defaults:defaults,claudeDiscovery:ClaudeSessionDiscovery(home:URL(fileURLWithPath:CommandLine.arguments[1]),listing:{[]},coworkDiscovery:ClaudeCoworkSessionDiscovery(roots:[])),dshDiscovery:DSHDesktopSessionDiscovery(leases:{[]}))).manuallyHidden,"hide survives restart")
  windows.setHidden(false);precondition(windows.visibleOwners==[pet.owner])
  windows.setHidden(true);windows.hide(pet.owner);windows.setHidden(false);precondition(windows.visibleOwners.isEmpty,"restore cannot resurrect a revoked lease")
  windows.update([pet],selfID:pet.owner);windows.hideAll();windows.toggleVisibility();windows.toggleVisibility();precondition(windows.visibleOwners.isEmpty,"restore cannot revive disconnected pets")
  windows.conversation.stop();windows.hideAll();print("Pet menu: inside click, outside click, event delivery, reopen, Escape and deactivation PASS")
  print("Pet visibility: active bubble hide/restore, pet retained, hide, refresh, restart, restore and revoked leases PASS")
 }
}
