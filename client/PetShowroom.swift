import AppKit
import SwiftUI

// Observe the hosting window, not application focus: closing or covering the
// showcase must stop its animation without stopping the desktop-pet runtime.
struct ShowroomVisibility:NSViewRepresentable {
 @ObservedObject private var language=AppLocalization.shared
 @Binding var visible:Bool
 func makeNSView(context:Context)->Probe {let view=Probe();view.changed={value in DispatchQueue.main.async{visible=value}};return view}
 func updateNSView(_ view:Probe,context:Context){}
 final class Probe:NSView {
  var changed:((Bool)->Void)?
  private var observations:[NSObjectProtocol]=[]
  override func viewDidMoveToWindow(){
   super.viewDidMoveToWindow()
   observations.forEach{NotificationCenter.default.removeObserver($0)};observations=[]
   guard let window else{changed?(false);return}
   for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification] {
    observations.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main){[weak self,weak window] note in
     guard let self,let window else{return}
     self.changed?(note.name != NSWindow.willCloseNotification && window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized)
    })
   }
   changed?(window.isVisible && window.occlusionState.contains(.visible))
  }
  deinit {observations.forEach{NotificationCenter.default.removeObserver($0)}}
 }
}

final class ShowroomPresentation:ObservableObject {
 @Published var visible=false
 @Published var wave=PencilWave()
 @Published var editor:String?
 @Published var draft=PetAppearanceDraft(style:8)
 @Published var saving=false
 @Published var saveError=""
 @Published var menuPresented=false
 var saveTask:Task<Void,Never>?
 deinit {saveTask?.cancel()}
}

struct PetShowroomView:View {
 @ObservedObject private var language=AppLocalization.shared
 var courierActive=false
 @ObservedObject var model:V2ClientModel
 @Environment(\.accessibilityReduceMotion) private var reducedMotion
 @StateObject private var presentation=ShowroomPresentation()
 private var menuPresented:Bool {get{presentation.menuPresented} nonmutating set{presentation.menuPresented=newValue}}
 private var visible:Bool {get{presentation.visible} nonmutating set{presentation.visible=newValue}}
 private var wave:PencilWave {get{presentation.wave} nonmutating set{presentation.wave=newValue}}
 private var editor:String? {get{presentation.editor} nonmutating set{presentation.editor=newValue}}
 private var draft:PetAppearanceDraft {get{presentation.draft} nonmutating set{presentation.draft=newValue}}
 private var saving:Bool {get{presentation.saving} nonmutating set{presentation.saving=newValue}}
 private var saveError:String {get{presentation.saveError} nonmutating set{presentation.saveError=newValue}}
 private var saveTask:Task<Void,Never>? {get{presentation.saveTask} nonmutating set{presentation.saveTask=newValue}}
 private var style:Int {model.displayedStyle}
 private var atHome:Bool {model.displayedAtHome}
 private func begin(_ kind:String){guard model.initialAppearanceReady else{return};draft=PetAppearanceDraft(style:style);saveError="";editor=kind}
 private func cancel(){guard !saving else{return};draft.cancel();editor=nil;saveError=""}
 private func save(){
  guard draft.hasChanges,!saving else{return}
  if model.localMode {model.dressCompanion(draft.previewStyle);editor=nil;return}
  saving=true;saveError=""
  model.dressCompanion(draft.previewStyle)
  saveTask=Task{@MainActor in
   try? await Task.sleep(for:.seconds(6))
   guard !Task.isCancelled else{return}
   saving=false;saveError=L10n.text("尚未确认保存，请检查连接后重试。")
  }
 }
 var body:some View {
  VStack(spacing:20){
   if let editor {
    HStack{Button(L10n.text("‹ 返回"),action:cancel).buttonStyle(.plain).disabled(saving);Spacer();Text(editor=="outfit" ? L10n.text("换装"):L10n.text("换宠物")).font(PencilFont.text(18));Spacer()}
    PetArt(style:draft.previewStyle,size:230).frame(maxWidth:.infinity).padding(.vertical,10)
    Divider()
    if editor=="outfit" {
     HStack(spacing:16){ForEach(0..<2){outfit in
      appearanceChoice(style:PetSpecies.decode(style:draft.previewStyle).style(outfit:outfit),label:outfit==0 ? L10n.text("原装"):L10n.text("围巾"),selected:draft.previewStyle%2==outfit){draft.selectOutfit(outfit)}
     }}.frame(maxWidth:.infinity)
    }else{
     LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:16){
      ForEach(PetSpecies.displayOrder){species in
       appearanceChoice(style:species.style(outfit:draft.previewStyle%2),label:species.name,selected:PetSpecies.decode(style:draft.previewStyle)==species){draft.selectSpecies(species)}
        .overlay(alignment:.topLeading){if PetSpecies.decode(style:style)==species{Text(L10n.text("当前")).font(PencilFont.text(10)).padding(3).background(PetAppearance.sage,in:Capsule())}}
      }
     }
     Text(L10n.text("好友、身份与权限保持不变")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
    }
    PencilFeedback(message:saveError,size:12)
    HStack{Button(L10n.text("取消"),action:cancel).disabled(saving);Spacer();Button(saving ? L10n.text("正在保存…"):(editor=="outfit" ? L10n.text("保存装扮"):L10n.text("使用这只")),action:save).disabled(!draft.hasChanges || saving)}
   }else{
    Text(model.petLocationLabel).font(PencilFont.text(17)).foregroundStyle(PetAppearance.secondary).padding(.top,42)
    if !model.initialAppearanceReady {
     Color.clear.frame(height:348).frame(maxWidth:.infinity)
    }else if atHome {
     TimelineView(.animation(minimumInterval:PetSpecies.decode(style:style) == .bread ? 0.04:0.14,paused:!visible || reducedMotion)){context in
      let time=context.date.timeIntervalSinceReferenceDate
      PetArt(style:style,frame:showroomFrame(time:time,wave:PetSpecies.decode(style:style) == .bread ? nil:wave,reducedMotion:reducedMotion),size:280)
       .rotationEffect(.degrees(PetSpecies.decode(style:style) == .bread ? wave.sway(now:time,reducedMotion:reducedMotion):0),anchor:.bottom)
       .anchorPreference(key:SocialUnlockAnchors.self,value:.bounds){[.showroom:$0]}
       .opacity(courierActive ? 0:1)
       .scaleEffect(x:1,y:reducedMotion || !visible ? 1:1+0.006*sin(time*1.8),anchor:.bottom)
     }.frame(maxWidth:.infinity).padding(.vertical,34)
    }else{
     VStack(spacing:16){Image(systemName:"door.left.hand.open").font(.system(size:45,weight:.ultraLight));Text(L10n.text("回来时，我们在这里见。")).font(PencilFont.text(14))}.foregroundStyle(PetAppearance.secondary).frame(height:348).frame(maxWidth:.infinity)
    }
    HStack(spacing:12){
     Button(L10n.text("挥手")){model.waveCompanion()}
     Button(L10n.text("换装")){begin("outfit")}
    }.frame(maxWidth:.infinity).disabled(!model.initialAppearanceReady)
    if !atHome {
     Button(L10n.text("召回")){model.send("recall")}.disabled(!model.connected).accessibilityIdentifier("showroom-recall")
    }
   }
  }.frame(maxWidth:.infinity)
   .overlay(alignment:.topTrailing){
    if editor==nil {showroomMenu}
   }
   .background(ShowroomVisibility(visible:$presentation.visible).frame(width:0,height:0))
   .onAppear{if model.openOutfitRequested{begin("outfit");model.openOutfitRequested=false}}
   .onChange(of:model.openOutfitRequested){requested in if requested{begin("outfit");model.openOutfitRequested=false}}
   .onChange(of:model.displayedWave){[old=model.displayedWave] new in if new>old {wave.enqueue(count:min(Int(new-old),4),now:Date.timeIntervalSinceReferenceDate)}}
   .onChange(of:style){new in if saving,new==draft.previewStyle {saveTask?.cancel();saving=false;editor=nil}}
   .onChange(of:model.connected){connected in if !connected,saving {saveTask?.cancel();saving=false;saveError=L10n.text("连接已中断，外观尚未确认保存。")}}
   .onDisappear{menuPresented=false;saveTask?.cancel();saving=false}
 }
 private var showroomMenu:some View {
  Button{menuPresented.toggle()}label:{Image(systemName:"ellipsis").frame(width:32,height:32)}
   .buttonStyle(.plain).fixedSize()
   .accessibilityLabel(L10n.text("更多桌宠操作")).accessibilityIdentifier("showroom-more")
   .popover(isPresented:Binding(get:{menuPresented},set:{menuPresented=$0}),arrowEdge:.top){
    PencilMenu{
     PetVisibilityButton(pets:model.pets,willSelect:{menuPresented=false})
     Button(L10n.text("换宠物")){menuPresented=false;begin("species")}
     Button(L10n.text("找回桌宠")){menuPresented=false;model.pets.recoverAll()}
    }
   }
 }
 private func appearanceChoice(style:Int,label:String,selected:Bool,action:@escaping()->Void)->some View {
  Button(action:action){VStack(spacing:6){PetArt(style:style,size:104);Text(label).font(PencilFont.text(14))}.frame(maxWidth:.infinity).padding(6)
   .overlay(PencilOutline(radius:12).stroke(selected ? PetAppearance.accent:Color.clear,lineWidth:1))
   .overlay(alignment:.topTrailing){if selected{Image(systemName:"checkmark.circle.fill").foregroundStyle(PetAppearance.accent).padding(5)}}
  }.buttonStyle(.plain).disabled(saving).accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected:[])
 }
}

struct VisitingPetsView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 private var visitors:[V2PetDTO]{model.localMode ? []:(model.snapshot?.pets ?? []).filter{$0.ownerID != model.snapshot?.selfID}}
 var body:some View {
  if !visitors.isEmpty {VStack(alignment:.leading,spacing:12){
   Text(L10n.text("正在来访")).font(PencilFont.text(16))
   ForEach(visitors){pet in
    VStack(alignment:.leading,spacing:8){HStack{PetArt(style:pet.style,size:42);Text(pet.nickname);Spacer()};HStack{if let contact=model.snapshot?.contacts.first(where:{$0.id==pet.ownerID}){Button(L10n.text("聊天")){model.openAvatarChat(contact)}.disabled(model.avatarChatAvailability(contact) != .available)};Button(L10n.text("送客")){model.send("send_home",fields:["pet_id":pet.ownerID])}}}.disabled(!model.connected)
   }
   Divider()
  }}
 }
}
