import AppKit
import SwiftUI
import Combine

final class ConversationBubblePanel:NSPanel {
 override var canBecomeKey:Bool {true}
}

private final class VisitorBubbleHostingView<Content:View>:NSHostingView<Content> {
 override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
}

@MainActor private final class VisitorChatBubbleState:ObservableObject {
 @Published var chat:VisitorChatBubble
 init(_ chat:VisitorChatBubble){self.chat=chat}
}
private struct VisitorChatBubbleView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var state:VisitorChatBubbleState
 let open:()->Void
 var body:some View {
  Button(action:open){
   VStack(alignment:.leading,spacing:8){
    HStack(spacing:6){Image(systemName:"bubble.left");Text(state.chat.name+L10n.text(" 的 Agent")).lineLimit(1);Spacer(minLength:0);Image(systemName:"chevron.right")}.font(PencilFont.text(12)).foregroundStyle(PetAppearance.accent)
    Text(state.chat.isAnswer ? state.chat.message:L10n.notice(state.chat.message)).font(PencilFont.text(14)).foregroundStyle(PetAppearance.ink).lineLimit(state.chat.isAnswer ? 3:2).multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading)
   }.padding(13).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    .background(PetAppearance.surface,in:PencilOutline(radius:14))
    .overlay(PencilOutline(radius:14).stroke(PetAppearance.line.opacity(0.65),lineWidth:1)).padding(3)
  }.buttonStyle(.plain).help(L10n.text("打开与{0}的聊天", state.chat.name))
   .accessibilityLabel(state.chat.name+L10n.text(" 的聊天气泡，")+(state.chat.isAnswer ? state.chat.message:L10n.notice(state.chat.message))+L10n.text("，点击打开聊天"))
   .accessibilityIdentifier("visitor-chat-bubble-"+state.chat.ownerID)
 }
}

struct PetArt: View {
 @ObservedObject private var language=AppLocalization.shared
 let style:Int
 var frame:Int=0
 var size:CGFloat=110
 var body:some View {
  Group {if let image=MonsterSprites.image(style:style,frame:frame){Image(nsImage:image).resizable().interpolation(.high).scaledToFit()}else{Image(systemName:"pawprint")}}
   .frame(width:size,height:size).accessibilityLabel((style%2==1 ? L10n.text("戴围巾的"):"")+PetSpecies.decode(style:style).name)
 }
}
struct PetFigure:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var state:PetWindowState
 @Environment(\.accessibilityReduceMotion) private var reducedMotion
 var body:some View {TimelineView(.animation(minimumInterval:0.04,paused:reducedMotion || !state.animationVisible)){context in
  let wave=state.wave.frame(now:context.date.timeIntervalSinceReferenceDate,reducedMotion:reducedMotion)
  let blink = !reducedMotion && Int(context.date.timeIntervalSinceReferenceDate*5)%29==0
  let jump=CompletionMotion.offset(elapsed:context.date.timeIntervalSinceReferenceDate-state.completionStarted,enabled:state.completionAllowed,reduced:reducedMotion)
  VStack(spacing:0){PetArt(style:state.style,frame:PetSpecies.decode(style:state.style) == .bread ? (blink ? 3:0):(wave==0 && blink ? 3:wave)).rotationEffect(.degrees(PetSpecies.decode(style:state.style) == .bread ? state.wave.sway(now:context.date.timeIntervalSinceReferenceDate,reducedMotion:reducedMotion):0),anchor:.bottom).offset(y:jump);if state.visitor {Text(L10n.text("{0} · 来访", state.name)).font(PencilFont.text(12)).padding(.horizontal,9).padding(.vertical,4).background(.regularMaterial,in:Capsule())}else if !state.agentSummary.isEmpty {Text(L10n.notice(state.agentSummary)).font(PencilFont.text(11)).lineLimit(1).padding(4).background(.regularMaterial,in:Capsule())}else{Color.clear.frame(height:26).accessibilityHidden(true)}}.padding(8)
 }}
}
@MainActor final class PetWindowState:ObservableObject { @Published var style:Int;@Published var name:String;@Published var visitor:Bool;@Published var wave=PencilWave();@Published var agentSummary="";@Published var completionStarted = -Double.infinity;@Published var completionAllowed=true;@Published var animationVisible=false;init(pet:Pet,visitor:Bool){style=pet.style;name=pet.name;self.visitor=visitor} }
@MainActor final class PetWindows:ObservableObject {
 @Published private(set) var manuallyHidden=false
 var openOutfit:(()->Void)?
 var openVisitorChat:((String)->Void)?
 private let visibility:PetVisibilityStore
 private var eligible=Set<String>()
 private let quickMenu=PetQuickMenuPopover()
 func toggleVisibility(){setHidden(!manuallyHidden)}
 func setHidden(_ hidden:Bool){manuallyHidden=hidden;visibility.hidden=hidden;quickMenu.close();for (id,state) in states{state.animationVisible = !hidden && eligible.contains(id)};if hidden {for panel in windows.values{panel.orderOut(nil)}}else{for id in eligible{windows[id]?.orderFrontRegardless()}};updateBubbles()}
 private func showQuickMenu(owner:String,anchor:NSView){
  let appearance=preferences
  let menu=PetQuickMenu(conversation:conversation,outfit:{[weak self] in self?.quickMenu.close();self?.openOutfit?()},hide:{[weak self] in self?.setHidden(true)})
  let controller=NSHostingController(rootView:PencilRoot(preferences:appearance){menu})
  quickMenu.show(controller,anchor:anchor)
 }
 let preferences:PencilPreferences
 let conversation:CodexConversationMonitor
 private let conversationPopover=NSPopover()
 private var bubblePanel:NSPanel?
 private var visitorChats:[String:VisitorChatBubble]=[:]
 private var visitorBubblePanels:[String:NSPanel]=[:]
 private var visitorBubbleStates:[String:VisitorChatBubbleState]=[:]
 func setVisitorChats(_ chats:[VisitorChatBubble]){visitorChats=chats.reduce(into:[:]){$0[$1.ownerID]=$1};updateBubbles()}
 func activateVisitorChat(_ owner:String){guard visitorBubblePanels[owner]?.isVisible==true,eligible.contains(owner) else{return};openVisitorChat?(owner)}
 var visibleOwners:Set<String> {Set(windows.filter{$0.value.isVisible}.keys)}
 func frame(_ owner:String)->NSRect? {windows[owner]?.frame}
 private var windows:[String:NSPanel]=[:]
 private var states:[String:PetWindowState]=[:]
 private let positions:PetPositionStore
 private var positionOwners:[String:String]=[:]
 private var screenObserver:NSObjectProtocol?
 private var languageObservation:AnyCancellable?
 private var agentSummary=""
 func setAgentSummary(_ value:String){let value=conversation.automaticEnabled && conversation.bubblesEnabled ? (conversation.selected ? conversation.summary:value):"";agentSummary=value;for state in states.values where !state.visitor{state.agentSummary=value;state.completionAllowed=conversation.completionEnabled};updateBubbles()}
 init(profile:String="default",defaults:UserDefaults = .standard,conversation:CodexConversationMonitor?=nil){visibility=PetVisibilityStore(defaults:defaults,profile:profile);manuallyHidden=visibility.hidden;preferences=PencilPreferences(profile:profile,defaults:defaults);self.conversation=conversation ?? CodexConversationMonitor(defaults:defaults);positions=PetPositionStore(defaults:defaults,profile:profile);self.conversation.changed={[weak self] value in self?.setAgentSummary(value)};self.conversation.completed={[weak self] in guard let self else{return};for (id,state) in states where !state.visitor && windows[id]?.isVisible==true {state.completionStarted=Date.timeIntervalSinceReferenceDate}};screenObserver=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.restoreAfterScreenChange()}}
  languageObservation=AppLocalization.shared.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refreshLanguage()}}
 }
 private func refreshLanguage(){
  for (owner,panel) in windows{panel.title=L10n.text("PetLink 桌宠 {0}",owner);panel.setAccessibilityLabel(panel.title)}
  if let panel=bubblePanel{panel.title=L10n.text("PetLink 会话气泡");panel.setAccessibilityLabel(panel.title)}
  for (owner,panel) in visitorBubblePanels{panel.title=L10n.text("PetLink {0}的聊天气泡",visitorChats[owner]?.name ?? owner);panel.setAccessibilityLabel(panel.title)}
 }
 deinit {if let screenObserver{NotificationCenter.default.removeObserver(screenObserver)}}
 func update(_ pets:[Pet],selfID:String,selfPositionOwner:String?=nil){
  let ids=Set(pets.map(\.owner));eligible=ids;for id in Array(windows.keys) where !ids.contains(id){hide(id)}
  for pet in pets {
   // Offline and connected representations of our pet share the account's
   // position. Visitors keep their own independent position records.
   let positionOwner=pet.owner==selfID ? (selfPositionOwner ?? pet.owner):pet.owner
   let previousPositionOwner=positionOwners[pet.owner]
   positionOwners[pet.owner]=positionOwner
   let panel:NSPanel
   if let old=windows[pet.owner]{
    panel=old
    if previousPositionOwner != positionOwner {panel.setFrameOrigin(positions.restore(owner:positionOwner,size:panel.frame.size,screens:PetScreen.connected,fallback:panel.frame.origin))}
   }else{
    panel=NSPanel(contentRect:NSRect(x:0,y:0,width:180,height:160),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false;panel.level = .floating
    panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.isMovableByWindowBackground=false;panel.hidesOnDeactivate=false
    panel.title=L10n.text("PetLink 桌宠 {0}", pet.owner);panel.setAccessibilityLabel(panel.title)
    let screen=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1000,height:700)
    var candidate=NSRect(x:screen.maxX-210,y:screen.minY+30,width:180,height:160)
    for _ in 0...windows.count {
     if !windows.values.contains(where:{$0.frame.intersects(candidate)}){break}
     candidate.origin.x-=190
     if candidate.minX<screen.minX {candidate.origin.x=screen.maxX-210;candidate.origin.y+=170}
    }
    let state=PetWindowState(pet:pet,visitor:pet.owner != selfID);states[pet.owner]=state
    let appearance=preferences
    let content=NSHostingView(rootView:PencilRoot(preferences:appearance){PetFigure(state:state)})
    let drag=DraggableHostingView(content);drag.didMove={[weak self] origin in self?.savePosition(pet.owner,origin:origin)};panel.contentView=drag
    // Resolve SwiftUI's natural size before restoring the origin: its first
    // layout otherwise resizes the panel while preserving the old top edge.
    panel.setContentSize(content.fittingSize)
    panel.setFrameOrigin(positions.restore(owner:positionOwner,size:panel.frame.size,screens:PetScreen.connected,fallback:candidate.origin))
    drag.didRightClick={[weak self,weak drag] in guard let drag else{return};self?.showQuickMenu(owner:pet.owner,anchor:drag)}
    drag.didClick={[weak self] in
     guard let self,self.states[pet.owner]?.visitor==false else{return}
     self.conversation.allCollapsed.toggle()
    }
    windows[pet.owner]=panel
   }
   states[pet.owner]?.style=pet.style;states[pet.owner]?.name=pet.name;states[pet.owner]?.visitor=pet.owner != selfID
   states[pet.owner]?.agentSummary=pet.owner==selfID ? agentSummary:""
   // Arrival/home greeting changes only the content frame; display leases and
   // panel coordinates remain authoritative and hiding is always immediate.
   if !panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {states[pet.owner]?.wave.enqueue(count:1,now:Date.timeIntervalSinceReferenceDate)}
   states[pet.owner]?.animationVisible = !manuallyHidden
   if !manuallyHidden {panel.orderFrontRegardless()}
  }
  updateBubbles()
 }
 private func updateBubbles(){
  defer{updateVisitorBubbles()}
  guard conversation.bubblesEnabled,!conversation.bubbleSessions.isEmpty,
        let own=states.first(where:{!$0.value.visitor && windows[$0.key]?.isVisible==true}),let pet=windows[own.key] else{bubblePanel?.orderOut(nil);return}
  if bubblePanel==nil {
   let panel=ConversationBubblePanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
   panel.title=L10n.text("PetLink 会话气泡");panel.setAccessibilityLabel(panel.title);panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false;panel.level = .floating;panel.hidesOnDeactivate=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
   let monitor=conversation
   panel.contentView=NSHostingView(rootView:PencilRoot(preferences:preferences){ConversationBubbles(monitor:monitor)})
   bubblePanel=panel
  }
  guard let screen=NSScreen.screens.first(where:{$0.frame.contains(NSPoint(x:pet.frame.midX,y:pet.frame.midY))})?.visibleFrame ?? NSScreen.main?.visibleFrame else{bubblePanel?.orderOut(nil);return}
  let height=conversationBubbleHeight(conversation.bubbleSessions.map{($0.snapshot.progress,conversation.collapsed.contains($0.id))},allCollapsed:conversation.allCollapsed)
  let size=NSSize(width:min(340,screen.width),height:min(height,screen.height-20))
  let preferredY=pet.frame.maxY+8+size.height<=screen.maxY ? pet.frame.maxY+8:pet.frame.minY-size.height-8
  let origin=clampedPetOrigin(NSPoint(x:pet.frame.midX-size.width/2,y:preferredY),size:size,inside:screen)
  bubblePanel?.setFrame(NSRect(origin:origin,size:size),display:true)
  if bubblePanel?.isVisible==false{bubblePanel?.orderFrontRegardless()}
 }
 private func updateVisitorBubbles(){
  let active=Set(visitorChats.keys.filter{conversation.bubblesEnabled && eligible.contains($0) && states[$0]?.visitor==true && windows[$0]?.isVisible==true})
  for owner in Array(visitorBubblePanels.keys) where !active.contains(owner) {
   visitorBubblePanels.removeValue(forKey:owner)?.close();visitorBubbleStates.removeValue(forKey:owner)
  }
  for owner in active.sorted() {
   guard let chat=visitorChats[owner],let pet=windows[owner],let screen=petScreen(at:NSPoint(x:pet.frame.midX,y:pet.frame.midY),screens:PetScreen.connected)?.bounds else{continue}
   let panel:NSPanel
   if let existing=visitorBubblePanels[owner]{panel=existing;if visitorBubbleStates[owner]?.chat != chat{visitorBubbleStates[owner]?.chat=chat}}
   else {
    panel=ConversationBubblePanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    panel.isReleasedWhenClosed=false;panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false;panel.level = .floating;panel.hidesOnDeactivate=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
    let state=VisitorChatBubbleState(chat);visitorBubbleStates[owner]=state
    let appearance=preferences
    let open:()->Void = {[weak self] in self?.activateVisitorChat(owner)}
    panel.contentView=VisitorBubbleHostingView(rootView:PencilRoot(preferences:appearance){VisitorChatBubbleView(state:state,open:open)})
    visitorBubblePanels[owner]=panel
   }
   panel.title=L10n.text("PetLink {0}的聊天气泡", chat.name);panel.setAccessibilityLabel(panel.title)
   let size=NSSize(width:min(280,screen.width),height:min(chat.isAnswer ? 120:90,screen.height))
   let y=pet.frame.maxY+8+size.height<=screen.maxY ? pet.frame.maxY+8:pet.frame.minY-size.height-8
   let preferred=NSRect(origin:clampedPetOrigin(NSPoint(x:pet.frame.midX-size.width/2,y:y),size:size,inside:screen),size:size)
   let obstacles=([bubblePanel].compactMap{$0}+visitorBubblePanels.filter{$0.key != owner}.map{$0.value}).filter(\.isVisible).map(\.frame)
   let frame=visitorBubbleFrame(preferred:preferred,inside:screen,obstacles:obstacles)
   panel.setFrame(frame,display:true)
   if !panel.isVisible{panel.orderFrontRegardless()}
  }
 }
 func showBubbles(){updateBubbles();if bubblePanel?.isVisible==true {bubblePanel?.makeKeyAndOrderFront(nil)}}
 func hide(_ id:String){eligible.remove(id);states[id]?.animationVisible=false;windows[id]?.orderOut(nil);updateBubbles()}
 func hideAll(except owner:String?=nil){
  eligible=eligible.filter{$0==owner};visitorChats.removeAll();quickMenu.close()
  for (id,state) in states where id != owner{state.animationVisible=false}
  for (id,panel) in windows where id != owner{panel.orderOut(nil)}
  updateBubbles();conversationPopover.performClose(nil)
 }
 func wave(_ id:String,count:Int=1){guard windows[id]?.isVisible==true,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else{return};states[id]?.wave.enqueue(count:count,now:Date.timeIntervalSinceReferenceDate)}
 private func savePosition(_ owner:String,origin:NSPoint){if let screen=petScreen(at:NSPoint(x:origin.x+90,y:origin.y+80),screens:PetScreen.connected){positions.save(owner:positionOwners[owner] ?? owner,origin:origin,screen:screen)};updateBubbles()}
 private func restoreAfterScreenChange(){for (owner,panel) in windows {panel.setFrameOrigin(positions.restore(owner:positionOwners[owner] ?? owner,size:panel.frame.size,screens:PetScreen.connected,fallback:panel.frame.origin))};updateBubbles()}
 func recoverAll(){guard let screen=NSScreen.main?.visibleFrame else{return};var next=NSPoint(x:screen.maxX-210,y:screen.minY+30);for owner in windows.keys.sorted(){guard let panel=windows[owner],panel.isVisible else{continue};let origin=clampedPetOrigin(next,size:panel.frame.size,inside:screen);panel.setFrameOrigin(origin);savePosition(owner,origin:origin);next.x-=190;if next.x<screen.minX{next.x=screen.maxX-210;next.y+=170}}}
}
