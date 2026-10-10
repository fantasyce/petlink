import AppKit
import SwiftUI
import Combine

@MainActor final class PencilKeyboardNavigation:ObservableObject {
 @Published private(set) var enabled:Bool
 private let read:@MainActor ()->Bool
 private let notifications:NotificationCenter
 private var activation:NSObjectProtocol?
 private var keys:Any?
 init(read:(@MainActor ()->Bool)?=nil,notifications:NotificationCenter = .default){
  self.read=read ?? {NSApp.isFullKeyboardAccessEnabled};self.notifications=notifications;enabled=self.read()
  activation=notifications.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main){[weak self] _ in
   MainActor.assumeIsolated{self?.refresh()}
  }
  keys=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
   if event.keyCode==48 {self?.refresh()}
   return event
  }
 }
 private func refresh(){let current=read();if enabled != current {enabled=current}}
 deinit {
  if let activation {notifications.removeObserver(activation)}
  if let keys {NSEvent.removeMonitor(keys)}
 }
}

@MainActor struct PencilKeyboardRoot<Content:View>:View {
 @ObservedObject private var language=AppLocalization.shared
 @StateObject private var navigation=PencilKeyboardNavigation()
 @ViewBuilder let content:()->Content
 var body:some View {
  // NSHostingView caches focus eligibility when built. Recreate the view graph
  // only after this system policy changes; models and saved state stay outside.
  content().id(navigation.enabled)
 }
}

enum PencilTitlebar {
 @MainActor static func configure(_ window:NSWindow) {
  // Keep a real titled, resizable macOS window; only its chrome is replaced.
  window.styleMask.insert(.fullSizeContentView)
  window.titleVisibility = .hidden
  window.titlebarAppearsTransparent=true
  for type:NSWindow.ButtonType in [.closeButton,.miniaturizeButton,.zoomButton] {
   window.standardWindowButton(type)?.isHidden=true
  }
  window.collectionBehavior.insert(.fullScreenPrimary)
 }
}

struct PencilTitlebarHost:NSViewRepresentable {
 @ObservedObject private var language=AppLocalization.shared
 func makeNSView(context:Context)->PencilTitlebarView {PencilTitlebarView(frame:.zero)}
 func updateNSView(_ view:PencilTitlebarView,context:Context){view.needsDisplay=true;for button in view.subviews.compactMap({$0 as? PencilTrafficButton}){button.refreshLanguage()}}
}

final class PencilTrafficButton:NSButton {
 private let kind:Int
 private var hovered=false
 private var tracking:NSTrackingArea?
 init(kind:Int) {
  self.kind=kind
  super.init(frame:.zero)
  title="";isBordered=false;setButtonType(.momentaryChange)
  refreshLanguage()
  target=self;action=#selector(activate)
 }
 required init?(coder:NSCoder){fatalError("not implemented")}
 func refreshLanguage(){setAccessibilityLabel([L10n.text("关闭窗口"),L10n.text("最小化窗口"),L10n.text("进入或退出全屏")][kind]);toolTip=[L10n.text("关闭窗口（桌宠继续运行）"),L10n.text("最小化窗口"),L10n.text("进入或退出全屏")][kind]}
 @objc private func activate(){
  switch kind {case 0:window?.performClose(self);case 1:window?.performMiniaturize(self);default:window?.toggleFullScreen(self)}
 }
 override func updateTrackingAreas(){
  super.updateTrackingAreas()
  if let tracking {removeTrackingArea(tracking)}
  let next=NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
  addTrackingArea(next);tracking=next
 }
 override func mouseEntered(with event:NSEvent){hovered=true;needsDisplay=true}
 override func mouseExited(with event:NSEvent){hovered=false;needsDisplay=true}
 override func draw(_ dirtyRect:NSRect){
  let r=NSRect(x:6,y:6,width:17,height:17)
  let colors:[NSColor]=[NSColor(srgbRed:0.90,green:0.51,blue:0.43,alpha:1),NSColor(srgbRed:0.93,green:0.73,blue:0.36,alpha:1),NSColor(srgbRed:0.57,green:0.72,blue:0.48,alpha:1)]
  let p=NSBezierPath();p.move(to:NSPoint(x:r.midX,y:r.minY))
  p.curve(to:NSPoint(x:r.maxX,y:r.midY),controlPoint1:NSPoint(x:r.maxX-1,y:r.minY-0.4),controlPoint2:NSPoint(x:r.maxX+0.3,y:r.minY+4))
  p.curve(to:NSPoint(x:r.midX,y:r.maxY),controlPoint1:NSPoint(x:r.maxX+0.2,y:r.maxY-2),controlPoint2:NSPoint(x:r.midX+3,y:r.maxY+0.5))
  p.curve(to:NSPoint(x:r.minX,y:r.midY),controlPoint1:NSPoint(x:r.minX+2,y:r.maxY),controlPoint2:NSPoint(x:r.minX-0.3,y:r.maxY-3))
  p.curve(to:NSPoint(x:r.midX,y:r.minY),controlPoint1:NSPoint(x:r.minX-0.4,y:r.minY+2),controlPoint2:NSPoint(x:r.midX-4,y:r.minY));p.close()
  colors[kind].withAlphaComponent(isHighlighted ? 0.65:0.9).setFill();p.fill()
  NSGraphicsContext.saveGraphicsState();p.addClip()
  NSColor.white.withAlphaComponent(0.25).setStroke()
  for i in stride(from:-8,through:24,by:4){let line=NSBezierPath();line.move(to:NSPoint(x:r.minX+CGFloat(i),y:r.minY));line.line(to:NSPoint(x:r.minX+CGFloat(i)+9,y:r.maxY));line.lineWidth=0.6;line.stroke()}
  NSGraphicsContext.restoreGraphicsState()
  NSColor.labelColor.withAlphaComponent(0.65).setStroke();p.lineWidth=1;p.stroke()
  if hovered || window?.firstResponder === self {
   let mark=NSBezierPath();mark.lineWidth=1.2
   if kind==0 {mark.move(to:NSPoint(x:11,y:11));mark.line(to:NSPoint(x:18,y:18));mark.move(to:NSPoint(x:18,y:11));mark.line(to:NSPoint(x:11,y:18))}
   else if kind==1 {mark.move(to:NSPoint(x:10,y:14.5));mark.line(to:NSPoint(x:19,y:14.5))}
   else {mark.move(to:NSPoint(x:11,y:11));mark.line(to:NSPoint(x:18,y:18));mark.move(to:NSPoint(x:11,y:15));mark.line(to:NSPoint(x:11,y:11));mark.line(to:NSPoint(x:15,y:11));mark.move(to:NSPoint(x:14,y:18));mark.line(to:NSPoint(x:18,y:18));mark.line(to:NSPoint(x:18,y:14))}
   NSColor.black.withAlphaComponent(0.7).setStroke();mark.stroke()
  }
 }
}

final class PencilTitlebarView:NSView {
 var displayedTitle:String {"PetLink"}
 override init(frame:NSRect){
  super.init(frame:frame)
  for kind in 0..<3{addSubview(PencilTrafficButton(kind:kind))}
  setAccessibilityElement(false)
 }
 required init?(coder:NSCoder){fatalError("not implemented")}
 override var intrinsicContentSize:NSSize {NSSize(width:NSView.noIntrinsicMetric,height:48)}
 override func layout(){super.layout();for (i,button) in subviews.enumerated(){button.frame=NSRect(x:12+i*30,y:10,width:29,height:29)}}
 override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
 override func mouseDown(with event:NSEvent){
  if event.clickCount==2 {
   switch UserDefaults.standard.string(forKey:"AppleActionOnDoubleClick") {
   case "Minimize":window?.performMiniaturize(self)
   case "None":break
   default:window?.zoom(self)
   }
  }else{window?.performDrag(with:event)}
 }
 override func draw(_ dirtyRect:NSRect){
  let font=NSFont(name:PencilFont.name,size:25) ?? .systemFont(ofSize:25)
  let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail;paragraph.alignment = .center
  (displayedTitle as NSString).draw(in:pencilCenteredTitleRect(width:bounds.width),withAttributes:[.font:font,.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph])
  NSColor.separatorColor.setStroke();let line=NSBezierPath();line.move(to:NSPoint(x:0,y:0.5));line.line(to:NSPoint(x:bounds.width,y:0.5));line.lineWidth=0.6;line.stroke()
 }
}
