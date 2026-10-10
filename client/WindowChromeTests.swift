import AppKit
import Combine

final class KeyboardScrollDocument:NSView {override var isFlipped:Bool {true}}

@main struct WindowChromeTests {
 @MainActor static func main() {
  _ = NSApplication.shared
  var keyboardEnabled=false
  let notifications=NotificationCenter()
  var navigation:PencilKeyboardNavigation?=PencilKeyboardNavigation(read:{keyboardEnabled},notifications:notifications)
  var changes:[Bool]=[]
  let observation=navigation!.$enabled.dropFirst().sink{changes.append($0)}
  keyboardEnabled=true
  notifications.post(name:NSApplication.didBecomeActiveNotification,object:nil)
  assert(navigation?.enabled==true,"returning from System Settings must update an already-running focus graph")
  notifications.post(name:NSApplication.didBecomeActiveNotification,object:nil)
  assert(changes==[true],"unchanged activation must preserve the existing focus graph")
  keyboardEnabled=false
  notifications.post(name:NSApplication.didBecomeActiveNotification,object:nil)
  assert(changes==[true,false],"disabling keyboard navigation must also update the existing graph")
  weak var releasedNavigation=navigation
  navigation=nil
  assert(releasedNavigation==nil,"closing the root must remove keyboard observers without retaining it")
  releasedNavigation=nil
  observation.cancel()
  print("Keyboard navigation policy: activation refresh, unchanged graph, disable and observer cleanup PASS")
  let pageWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:300,height:200),styleMask:.borderless,backing:.buffered,defer:false)
  pageWindow.isReleasedWhenClosed=false
  let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:300,height:200))
  let document=KeyboardScrollDocument(frame:NSRect(x:0,y:0,width:300,height:1000))
  let pageKeys=PencilScrollKeyView(frame:document.bounds)
  document.addSubview(pageKeys);scroll.documentView=document;pageWindow.contentView=scroll
  pageWindow.orderFront(nil);pageWindow.contentView?.layoutSubtreeIfNeeded()
  func pageEvent(_ code:UInt16,_ windowNumber:Int,_ flags:NSEvent.ModifierFlags=[])->NSEvent {
   NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
  }
  let startY=scroll.contentView.bounds.minY
  assert(pageKeys.handlePageKey(pageEvent(121,pageWindow.windowNumber))==nil)
  let downY=scroll.contentView.bounds.minY
  assert(downY>startY,"Page Down must scroll the owning viewport")
  assert(pageKeys.handlePageKey(pageEvent(116,pageWindow.windowNumber))==nil)
  assert(scroll.contentView.bounds.minY<downY,"Page Up must make earlier controls reachable")
  assert(pageKeys.handlePageKey(pageEvent(121,0)) != nil,"a different window's keys must pass through")
  assert(pageKeys.handlePageKey(pageEvent(121,pageWindow.windowNumber,.command)) != nil,"modified keys must pass through")
  pageWindow.orderOut(nil);pageWindow.contentView=nil
  print("Keyboard pages: actual viewport scrolling, opposite direction, window scope and modifiers PASS")
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:680),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  window.isReleasedWhenClosed=false
  PencilTitlebar.configure(window)
  assert(window.titleVisibility == .hidden)
  assert(window.styleMask.contains(.titled) && window.styleMask.contains(.fullSizeContentView))
  assert(window.standardWindowButton(.closeButton)?.isHidden==true)
  assert(window.standardWindowButton(.miniaturizeButton)?.isHidden==true)
  assert(window.standardWindowButton(.zoomButton)?.isHidden==true)
  let bar=PencilTitlebarView(frame:NSRect(x:0,y:0,width:760,height:48))
  window.contentView=bar
  window.title="PetLink · test-profile"
  assert(bar.displayedTitle=="PetLink","visible title stays centered and free of debug profile")
  assert(window.title.contains("test-profile"),"native window identity still distinguishes test profiles")
  bar.layoutSubtreeIfNeeded()
  let buttons=bar.subviews.compactMap{$0 as? NSButton}
  assert(buttons.count==3)
  assert(buttons.map{$0.accessibilityLabel() ?? ""} == ["关闭窗口","最小化窗口","进入或退出全屏"])
  assert(buttons.allSatisfy{$0.frame.width>=28 && $0.frame.height>=28})
  assert(bar.hitTest(NSPoint(x:26,y:24)) is NSButton,"window drag must not swallow a control")
  assert(bar.hitTest(NSPoint(x:400,y:24)) === bar,"blank header must remain draggable")
  window.orderFront(nil)
  buttons[1].performClick(nil)
  RunLoop.main.run(until:Date().addingTimeInterval(0.5))
  assert(window.isMiniaturized,"custom yellow button must actually minimize")
  window.deminiaturize(nil)
  buttons[0].performClick(nil)
  assert(!window.isVisible,"custom red button must actually close")
  print("Custom titlebar native window capabilities, accessible controls and drag hit areas passed")
 }
}
