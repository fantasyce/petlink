import AppKit
import SwiftUI
import CoreText

enum PencilFont {
 static let name="Yozai-Regular"
 static func register(resources:URL? = Bundle.main.resourceURL) {
  guard let url=resources?.appendingPathComponent("Yozai-Regular.ttf") else{return}
  CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)
 }
 static func text(_ size:CGFloat=14)->Font {.custom(name,size:size)}
}

enum PetAppearance {
 static func dynamic(_ light:UInt32,_ dark:UInt32)->Color {
  Color(nsColor:NSColor(name:nil){appearance in
   let n=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark:light
   return NSColor(srgbRed:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255,alpha:1)
  })
 }
 static let accent=dynamic(0x416C4D,0xB8D7BF)
 static let canvas=dynamic(0xFAFAF7,0x202220)
 static let surface=dynamic(0xFFFFFF,0x2A2D29)
 static let ink=dynamic(0x30312E,0xF1F2ED)
 static let secondary=dynamic(0x62645F,0xB6BAB2)
 static let line=dynamic(0x92958D,0x90958B)
 static let sage=dynamic(0xEAF0E5,0x35473A)
 static let coral=dynamic(0xF7E1D9,0x563F38)
}

private struct PencilNoticeHeight:PreferenceKey {
 static var defaultValue:CGFloat=0
 static func reduce(value:inout CGFloat,nextValue:()->CGFloat){value=max(value,nextValue())}
}

private final class PencilNoticePresentation:ObservableObject {
 @Published var retained:AnyView?
 @Published var height:CGFloat=0
 @Published var progress:CGFloat=0
 var visible=false
}

// One animated layout value drives both the concealed text and the space it
// reserves. Retaining the last content lets clearing a message animate out.
struct PencilNoticeRegion<Content:View>:View {
 @ObservedObject private var language=AppLocalization.shared
 let isPresented:Bool
 var identity:String=""
 var spacing:CGFloat=0
 @ViewBuilder var content:()->Content
 @Environment(\.accessibilityReduceMotion) private var reducedMotion
 @StateObject private var presentation=PencilNoticePresentation()
 var body:some View {
  (isPresented ? AnyView(content()):(presentation.retained ?? AnyView(Color.clear.frame(height:0))))
   .frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
   .background(GeometryReader{geometry in Color.clear.preference(key:PencilNoticeHeight.self,value:geometry.size.height)})
   .modifier(PencilNoticeLayout(progress:presentation.progress,height:presentation.height,spacing:spacing))
   .allowsHitTesting(isPresented).accessibilityHidden(!isPresented)
   .onPreferenceChange(PencilNoticeHeight.self){new in
    guard new>0,abs(presentation.height-new)>0.5 else{return}
    if presentation.height==0 {presentation.height=new}else{withAnimation(animation){presentation.height=new}}
    if presentation.visible {withAnimation(animation){presentation.progress=1}}
   }
   .onAppear{update(isPresented)}
   .onChange(of:isPresented){visible in update(visible)}
   .onChange(of:identity){_ in if presentation.visible{presentation.retained=AnyView(content())}}
   .onChange(of:reducedMotion){_ in update(presentation.visible)}
 }
 private var animation:Animation? {reducedMotion ? nil:.timingCurve(1.0/3,0,2.0/3,1,duration:PencilNoticeMotion.duration)}
 private func update(_ visible:Bool){
  presentation.visible=visible
  if visible {presentation.retained=AnyView(content())}
  withAnimation(animation){presentation.progress=visible && presentation.height>0 ? 1:0}
 }
}

struct PencilNoticeLayout:AnimatableModifier {
 var progress:CGFloat
 var height:CGFloat
 var spacing:CGFloat
 var animatableData:AnimatablePair<CGFloat,CGFloat> {
  get{AnimatablePair(progress,height)}
  set{progress=newValue.first;height=newValue.second}
 }
 func body(content:Content)->some View {
  let layout=PencilNoticeMotion.layout(height:Double(height),spacing:Double(spacing),progress:Double(progress))
  content.offset(y:layout.messageOffset).opacity(min(1,max(0,Double(progress)*1.5)))
   .frame(height:layout.reservedHeight,alignment:.top).clipped()
 }
}

struct PencilFeedback:View {
 @ObservedObject private var language=AppLocalization.shared
 let message:String
 var size:CGFloat=13
 var body:some View {
  PencilNoticeRegion(isPresented:!message.isEmpty,identity:message){
   Text(L10n.notice(message)).font(PencilFont.text(size)).foregroundStyle(PetAppearance.secondary).fixedSize(horizontal:false,vertical:true)
  }
 }
}

// Deterministic curves: redraws and presses never randomly move a control.
struct PencilOutline:Shape {
 var radius:CGFloat=10
 func path(in r:CGRect)->Path {
  let r=r.insetBy(dx:1,dy:1),c=min(radius,min(r.width,r.height)/2)
  var p=Path();p.move(to:CGPoint(x:r.minX+c,y:r.minY+0.3))
  p.addQuadCurve(to:CGPoint(x:r.maxX-c,y:r.minY),control:CGPoint(x:r.midX,y:r.minY+0.8))
  p.addQuadCurve(to:CGPoint(x:r.maxX,y:r.minY+c),control:CGPoint(x:r.maxX,y:r.minY))
  p.addQuadCurve(to:CGPoint(x:r.maxX-0.3,y:r.maxY-c),control:CGPoint(x:r.maxX-0.6,y:r.midY))
  p.addQuadCurve(to:CGPoint(x:r.maxX-c,y:r.maxY),control:CGPoint(x:r.maxX,y:r.maxY))
  p.addQuadCurve(to:CGPoint(x:r.minX+c,y:r.maxY-0.2),control:CGPoint(x:r.midX,y:r.maxY-0.7))
  p.addQuadCurve(to:CGPoint(x:r.minX,y:r.maxY-c),control:CGPoint(x:r.minX,y:r.maxY))
  p.addQuadCurve(to:CGPoint(x:r.minX+0.3,y:r.minY+c),control:CGPoint(x:r.minX+0.7,y:r.midY))
  p.addQuadCurve(to:CGPoint(x:r.minX+c,y:r.minY+0.3),control:CGPoint(x:r.minX,y:r.minY));p.closeSubpath();return p
 }
}

struct PencilButtonStyle:ButtonStyle {
 var hovering=false
 @Environment(\.isEnabled) private var enabled
 func makeBody(configuration:Configuration)->some View {
  configuration.label.font(PencilFont.text()).padding(.horizontal,12).padding(.vertical,6)
   .foregroundStyle(enabled ? PetAppearance.ink:PetAppearance.secondary)
   .background(configuration.isPressed || hovering ? PetAppearance.sage:(configuration.role == .destructive ? PetAppearance.coral:PetAppearance.surface),in:PencilOutline())
   .overlay(PencilOutline().stroke(PetAppearance.line.opacity(enabled ? 0.85:0.35),lineWidth:1))
   // The filled background already defines the button's full click area. An
   // extra contentShape here breaks wrapped notice buttons on macOS 13.
   .opacity(enabled ? 1:0.48)
 }
}
struct PencilTextFieldStyle:TextFieldStyle {
 @FocusState private var focused:Bool
 func _body(configuration:TextField<Self._Label>)->some View {
  configuration.font(PencilFont.text()).textFieldStyle(.plain).focused($focused).padding(9)
   .background(PetAppearance.surface,in:PencilOutline())
   .overlay(PencilOutline().stroke(focused ? PetAppearance.accent:PetAppearance.line.opacity(0.7),lineWidth:focused ? 2:1).allowsHitTesting(false))
 }
}
struct PencilToggleStyle:ToggleStyle {
 // Changing the style value refreshes cached state labels as well as the title.
 var languageID=AppLocalization.shared.languageID
 func makeBody(configuration:Configuration)->some View {
  HStack {configuration.label;Spacer(minLength:12)
   Button {configuration.isOn.toggle()} label:{
    ZStack(alignment:configuration.isOn ? .trailing:.leading) {
     PencilOutline(radius:15).fill(configuration.isOn ? PetAppearance.sage:PetAppearance.surface)
     PencilOutline(radius:15).stroke(PetAppearance.line,lineWidth:1)
     Circle().fill(PetAppearance.surface).overlay(Circle().stroke(PetAppearance.line,lineWidth:1)).padding(3).frame(width:25)
    }.frame(width:43,height:25)
   }.buttonStyle(.plain).accessibilityLabel(configuration.isOn ? L10n.text("已开启"):L10n.text("已关闭"))
  }.accessibilityElement(children:.combine).accessibilityValue(configuration.isOn ? L10n.text("开启"):L10n.text("关闭"))
 }
}

struct PencilRoot<Content:View>:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var preferences:PencilPreferences
 @ViewBuilder var content:()->Content
 var body:some View {
  content().font(PencilFont.text()).foregroundStyle(PetAppearance.ink)
   .buttonStyle(PencilButtonStyle()).toggleStyle(PencilToggleStyle(languageID:language.languageID)).tint(PetAppearance.accent)
   .preferredColorScheme(preferences.appearance == .system ? nil:(preferences.appearance == .dark ? .dark:.light))
   .environmentObject(preferences).environment(\.locale,language.locale)
 }
}

private struct PencilScrollTargetKey:FocusedValueKey {typealias Value=String}
extension FocusedValues {
 var pencilScrollTarget:String? {
  get {self[PencilScrollTargetKey.self]}
  set {self[PencilScrollTargetKey.self]=newValue}
 }
}
extension View {
 func pencilFocusTarget(_ id:String)->some View {self.id(id).focusedValue(\.pencilScrollTarget,id)}
}
struct PencilScrollView<Content:View>:View {
 @ObservedObject private var language=AppLocalization.shared
 @FocusedValue(\.pencilScrollTarget) private var focusedTarget:String?
 @ViewBuilder let content:()->Content
 var body:some View {
  ScrollViewReader {proxy in
   ScrollView {content().background(PencilScrollKeys())}.onChange(of:focusedTarget){target in
    // A nil anchor reveals only what is needed, preserving the user's scroll.
    if let target {proxy.scrollTo(target)}
   }
  }
 }
}

final class PencilScrollKeyView:NSView {
 private var keys:Any?
 override func hitTest(_ point:NSPoint)->NSView? {nil}
 override func viewDidMoveToWindow(){
  super.viewDidMoveToWindow()
  if let keys {NSEvent.removeMonitor(keys);self.keys=nil}
  guard window != nil else{return}
  keys=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in guard let self else{return event};return self.handlePageKey(event)}
 }
 func handlePageKey(_ event:NSEvent)->NSEvent? {
  guard event.window === window,window != nil,
        event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
        let scroll=enclosingScrollView else{return event}
  let direction:CGFloat
  switch event.keyCode {case 116:direction = -1;case 121:direction = 1;default:return event}
  let clip=scroll.contentView
  var bounds=clip.bounds
  let page=max(1,bounds.height-scroll.verticalPageScroll)
  bounds.origin.y += direction*page*(scroll.documentView?.isFlipped == true ? 1 : -1)
  clip.scroll(to:clip.constrainBoundsRect(bounds).origin)
  scroll.reflectScrolledClipView(clip)
  return nil
 }
 deinit {if let keys {NSEvent.removeMonitor(keys)}}
}
private struct PencilScrollKeys:NSViewRepresentable {
 @ObservedObject private var language=AppLocalization.shared
 func makeNSView(context:Context)->PencilScrollKeyView {let view=PencilScrollKeyView();view.setAccessibilityElement(false);return view}
 func updateNSView(_ view:PencilScrollKeyView,context:Context){}
}

enum MonsterSprites {
 static let atlases:[PetSpecies:[NSImage]] = Dictionary(uniqueKeysWithValues:PetSpecies.allCases.map {species in
  guard let url=Bundle.main.url(forResource:species.asset,withExtension:"png"),let image=NSImage(contentsOf:url),let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else{return (species,[])}
  let w=cg.width/4,h=cg.height/2
  let frames=(0..<8).compactMap {i in cg.cropping(to:CGRect(x:(i%4)*w,y:(i/4)*h,width:w,height:h)).map{NSImage(cgImage:$0,size:NSSize(width:110,height:110))}}
  return (species,frames)
 })
 static func image(style:Int,frame:Int)->NSImage? {
  let frames=atlases[PetSpecies.decode(style:style)] ?? []
  let index=(style%2==1 ? 4:0)+max(0,min(frame,3))
  return frames.indices.contains(index) ? frames[index]:nil
 }
}

struct PencilAppearanceSettings:View {
 @ObservedObject private var language=AppLocalization.shared
 @EnvironmentObject private var preferences:PencilPreferences
 var body:some View {
  PencilSegments(title:L10n.text("外观"),selection:$preferences.appearance,options:[(.light,L10n.text("浅色")),(.dark,L10n.text("深色")),(.system,L10n.text("跟随系统"))])
 }
}

struct PencilSegments<Value:Hashable>:View {
 @ObservedObject private var language=AppLocalization.shared
 let title:String
 @Binding var selection:Value
 let options:[(Value,String)]
 var body:some View {
  ViewThatFits(in:.horizontal){
   HStack(spacing:10){heading;choices}.fixedSize(horizontal:true,vertical:false)
   VStack(alignment:.leading,spacing:8){heading;choices}
  }
 }
 private var heading:some View{Text(title).foregroundStyle(PetAppearance.secondary)}
 private var choices:some View{HStack(spacing:10){ForEach(options,id:\.0){item in
  Button {selection=item.0} label:{HStack(spacing:4){if selection==item.0{Image(systemName:"checkmark").font(.system(size:10))};Text(item.1)}}
   .pencilFocusTarget("appearance-\(item.1)")
   .accessibilityAddTraits(selection==item.0 ? .isSelected:[])
 }}}
}

struct PencilLanguageSettings:View {
 @ObservedObject private var language=AppLocalization.shared
 var body:some View {
  PencilSegments(title:L10n.text("语言"),selection:Binding(get:{language.selection},set:{language.select($0)}),options:[(.system,L10n.text("跟随系统")),(.chinese,"简体中文"),(.english,"English")])
   .accessibilityIdentifier("language-selection")
 }
}

@MainActor final class PetQuickMenuPopover:NSObject,NSPopoverDelegate {
 private let popover=NSPopover()
 private var monitors:[Any]=[]
 private var deactivationObserver:NSObjectProtocol?
 override init(){super.init();popover.behavior = .transient;popover.delegate=self}
 func show(_ controller:NSViewController,anchor:NSView){
  close()
  popover.contentViewController=controller
  popover.contentSize=controller.view.fittingSize
  popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
  guard popover.isShown else{return}
  // Nonactivating pet panels cannot rely on the popover's focus dismissal.
  // Observe both our windows and other apps without consuming outside clicks.
  let clicks:NSEvent.EventTypeMask=[.leftMouseDown,.rightMouseDown,.otherMouseDown]
  if let monitor=NSEvent.addLocalMonitorForEvents(matching:[clicks,.keyDown],handler:{[weak self] event in
   guard let self else{return event}
   if event.type == .keyDown {
    if event.keyCode==53 {self.close();return nil}
   }else if event.window !== self.popover.contentViewController?.view.window {self.close()}
   return event
  }){monitors.append(monitor)}
  if let monitor=NSEvent.addGlobalMonitorForEvents(matching:clicks,handler:{[weak self] _ in self?.close()}){monitors.append(monitor)}
  deactivationObserver=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.close()}}
 }
 func close(){stopMonitoring();popover.performClose(nil)}
 func popoverWillClose(_ notification:Notification){stopMonitoring()}
 private func stopMonitoring(){
  for monitor in monitors {NSEvent.removeMonitor(monitor)}
  monitors.removeAll()
  if let deactivationObserver {NotificationCenter.default.removeObserver(deactivationObserver);self.deactivationObserver=nil}
 }
 deinit {
  for monitor in monitors {NSEvent.removeMonitor(monitor)}
  if let deactivationObserver {NotificationCenter.default.removeObserver(deactivationObserver)}
 }
}


private struct PencilMenuButtonStyle:ButtonStyle {
 func makeBody(configuration:Configuration)->some View {Content(configuration:configuration)}
 private final class Hover:ObservableObject {@Published var active=false}
 private struct Content:View {
 @ObservedObject private var language=AppLocalization.shared
  let configuration:ButtonStyleConfiguration
  @Environment(\.isEnabled) private var enabled
  @StateObject private var hover=Hover()
  var body:some View {PencilButtonStyle(hovering:hover.active).makeBody(configuration:configuration).onHover{hover.active=enabled && $0}}
 }
}

struct PencilMenu<Content:View>:View {
 @ObservedObject private var language=AppLocalization.shared
 @ViewBuilder let content:()->Content
 var body:some View {VStack(alignment:.leading,spacing:8,content:content).buttonStyle(PencilMenuButtonStyle()).padding(10).fixedSize()
  .background(PetAppearance.canvas)
  .overlay(PencilOutline(radius:12).stroke(PetAppearance.line,lineWidth:1).padding(3).allowsHitTesting(false))}
}

struct PencilContextMenuAnchor<Content:View>:NSViewRepresentable {
 @ObservedObject private var language=AppLocalization.shared
 @EnvironmentObject private var preferences:PencilPreferences
 @ViewBuilder let content:(@escaping ()->Void)->Content
 final class Anchor:NSView {
  let popup=PetQuickMenuPopover()
  var open:(()->Void)?
  override func hitTest(_ point:NSPoint)->NSView? {NSApp.currentEvent?.type == .rightMouseDown && bounds.contains(convert(point,from:superview)) ? self:nil}
  override func rightMouseDown(with event:NSEvent){open?()}
 }
 func makeNSView(context:Context)->Anchor {let view=Anchor();updateNSView(view,context:context);return view}
 func updateNSView(_ view:Anchor,context:Context){
  let menuContent=content({[weak view] in view?.popup.close()}),appearance=preferences
  view.open={[weak view] in guard let view else{return};view.popup.show(NSHostingController(rootView:PencilRoot(preferences:appearance){PencilMenu{menuContent}}),anchor:view)}
 }
 static func dismantleNSView(_ view:Anchor,coordinator:()){view.popup.close();view.open=nil}
}
