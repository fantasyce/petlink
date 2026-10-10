import AppKit
import SwiftUI

private final class NoticeFixture:ObservableObject {
 @Published var message=""
 @Published var revision=0
 @Published var clicks=0
 let marker=NSView()
 let contentMarker=NSView()
}
private struct NoticeMarker:NSViewRepresentable {
 let view:NSView
 var revision:Int=0
 func makeNSView(context:Context)->NSView{view}
 func updateNSView(_ view:NSView,context:Context){view.identifier=NSUserInterfaceItemIdentifier(String(revision))}
}
private struct NoticeFixtureView:View {
 @ObservedObject var fixture:NoticeFixture
 var body:some View {
  VStack(spacing:0){PencilTitlebarHost().frame(height:48);TimelineView(.animation(minimumInterval:1.0/30,paused:true)){_ in PencilScrollView {VStack(spacing:0){
   PencilNoticeRegion(isPresented:!fixture.message.isEmpty,identity:fixture.message,spacing:20){HStack{Text(fixture.message).font(PencilFont.text(13));Spacer();NoticeMarker(view:fixture.contentMarker,revision:fixture.revision).frame(width:1,height:1);Button("修改昵称"){fixture.clicks+=1;fixture.message="";if CommandLine.arguments.contains("--interactive"){NSApp.stop(nil)}}.buttonStyle(PencilButtonStyle())}.padding(12).background(PetAppearance.surface,in:PencilOutline()).accessibilityIdentifier("default-nickname-notice")}
   PencilNoticeRegion(isPresented:false){Text("")}
   PencilNoticeRegion(isPresented:false){Text("")}
   PencilNoticeRegion(isPresented:false){Text("")}
   NoticeMarker(view:fixture.marker).frame(height:20)
   Spacer(minLength:0)
  }.padding(18).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)}}}.ignoresSafeArea(.container,edges:.top)
 }
}
@main struct PencilNoticeViewTests {
 @MainActor static func main(){
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.accessory)
  NSApp.activate(ignoringOtherApps:true)
  let fixture=NoticeFixture()
  let host=NSHostingView(rootView:NoticeFixtureView(fixture:fixture))
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  PencilTitlebar.configure(window)
  window.isReleasedWhenClosed=false;window.contentView=host;window.orderFront(nil)
  defer{window.orderOut(nil);window.contentView=nil}
  func wait(_ seconds:Double){RunLoop.main.run(until:Date().addingTimeInterval(seconds));host.layoutSubtreeIfNeeded()}
  func y()->CGFloat{fixture.marker.convert(.zero,to:host).y}
  wait(0.2);let original=y()
  FileHandle.standardError.write(Data("host frame \(host.frame) window \(window.isVisible) marker \(fixture.marker.frame)\n".utf8))
  fixture.message="已为你取名「小伙伴星星」，可以换成喜欢的昵称。"
  wait(0.3);let early=abs(y()-original)
  wait(1.1);let opened=abs(y()-original)
  FileHandle.standardError.write(Data("notice motion sample: original=\(original), early=\(early), opened=\(opened)\n".utf8))
  precondition(early>0 && early<opened*0.75,"notice must reveal gradually, moving subsequent content rather than jumping")
  precondition(opened>40,"wrapped notice must reserve its actual measured content height")
  fixture.revision=1;wait(0.1)
  precondition(fixture.contentMarker.identifier?.rawValue=="1","visible notice must use current content and actions, not a cached view snapshot")
  if CommandLine.arguments.contains("--interactive") {
   // NSApplication's event pump is required for actual mouse delivery;
   // running RunLoop alone can render the window but cannot dispatch clicks.
   NSApp.run()
   precondition(fixture.clicks==1,"the real wrapped notice button must respond to a mouse click")
   wait(1.3)
   precondition(abs(y()-original)<1,"clicking the notice action must animate its space away")
   print("PASS native wrapped notice mouse action and animated dismissal")
   return
  }
  fixture.message=""
  wait(0.25);let closing=abs(y()-original)
  precondition(closing>opened*0.4 && closing<opened,"clearing message must retain its old content and animate its space away")
  wait(1.15)
  precondition(abs(y()-original)<1,"following content must return exactly to its original location")
  fixture.message="再次显示"
  wait(0.3);fixture.message="";wait(1.3)
  precondition(abs(y()-original)<1,"interrupted entry must reverse without leaving reserved space")
  print("PASS native notice view: gradual insertion, wrapped text sizing, retained removal, exact return and interrupted reversal")
 }
}
