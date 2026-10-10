import AppKit
import SwiftUI


@MainActor extension V2ClientModel {
 var pendingAvatarCount:Int { (snapshot?.avatarTasks ?? []).filter { $0.task.ownerID == snapshot?.selfID && $0.task.state == "pending_approval" }.count }
 var pendingSocialCount:Int { (snapshot?.friendRequests.count ?? 0)+(snapshot?.visitRequests.count ?? 0) }
 var attentionCount:Int { pendingSocialCount+pendingAvatarCount }
 func canVisit(_ contact:V2ContactDTO)->Bool {
  canVisitFromUI(connected:connected,online:contact.online,accepting:contact.accepting,phase:snapshot?.own.phase ?? "",pending:!(snapshot?.outgoingVisits.isEmpty ?? true))
 }
 var petLocationLabel:String {
  if localMode{return L10n.text("在家")}
  guard let pet=snapshot?.own else{return L10n.text("正在确认位置")}
  if pet.phase == "home" {return L10n.text("在家")}
  if pet.phase == "travel" {return L10n.text("正在路上")}
  return L10n.text("正在 {0} 家做客", contactName(pet.locationID))
 }
}

struct ConnectionLabel:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 var body:some View {
  Label(model.connected ? L10n.text("已连接"):(model.friendInteractionEnabled ? L10n.text("未连接"):L10n.text("好友互动已关闭")),systemImage:model.connected ? "circle.fill":"circle")
   .font(PencilFont.text(12)).foregroundStyle(model.connected ? PetAppearance.accent:Color.secondary)
 }
}

struct WorkspaceView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 @Environment(\.accessibilityReduceMotion) private var reducedMotion
 @StateObject private var unlock=SocialUnlockPresentation()
 private let pages:[(Int,String,String)]=[(0,L10n.text("我的桌宠"),"pawprint"),(1,L10n.text("联系人"),"person.2"),(2,L10n.text("请求"),"tray"),(3,L10n.text("本地会话"),"terminal"),(4,L10n.text("设置"),"slider.horizontal.3")]
 private var title:String { pages.first{$0.0==model.selectedTab}?.1 ?? L10n.text("我的桌宠") }
 var body:some View {
  TimelineView(.animation(minimumInterval:1.0/30,paused:unlock.started==nil || reducedMotion)) { context in
   let elapsed=unlock.started.map{context.date.timeIntervalSinceReferenceDate-$0} ?? SocialUnlockMotion.duration
  VStack(spacing:0) {
    if model.authenticated,model.selectedTab==1,!model.selectedAvatarOwner.isEmpty {AvatarChatView(model:model)}else{
    PencilScrollView {
     VStack(alignment:.leading,spacing:0) {
      PencilNoticeRegion(isPresented:model.authenticated && model.profileInfo?.nicknameIsDefault == true && unlock.started == nil,identity:model.profileInfo?.nickname ?? "",spacing:20){HStack{Text(L10n.text("已为你取名「{0}」，可以换成喜欢的昵称。", model.profileInfo?.nickname ?? "")).font(PencilFont.text(13));Spacer();Button(L10n.text("修改昵称")){model.nicknameDraft=model.profileInfo?.nickname ?? "";model.editingNickname=true;model.selectedTab=4}.buttonStyle(PencilButtonStyle())}.padding(12).background(PetAppearance.surface,in:PencilOutline(radius:8)).accessibilityIdentifier("default-nickname-notice")}
      PencilNoticeRegion(isPresented:!model.operationNotice.isEmpty,identity:model.operationNotice,spacing:20){HStack(alignment:.top){Image(systemName:"info.circle");Text(L10n.notice(model.operationNotice));Spacer();Button {model.operationNotice=""} label:{Image(systemName:"xmark")}.buttonStyle(.plain).accessibilityLabel(L10n.text("关闭提示"))}.padding(12).background(PetAppearance.surface,in:PencilOutline(radius:8)).accessibilityIdentifier("operation-notice")}
      PencilNoticeRegion(isPresented:!model.credentialWarning.isEmpty && (!L10n.notice(model.credentialWarning).contains(L10n.text("未使用钥匙串")) || model.selectedTab==4),identity:model.credentialWarning,spacing:20){VStack(alignment:.leading,spacing:12){Label(L10n.notice(model.credentialWarning),systemImage:"exclamationmark.shield").font(PencilFont.text(14));Button(L10n.text("重试保存凭据")){model.saveIdentity()}}}
      PencilNoticeRegion(isPresented:!model.recoveryCode.isEmpty,identity:model.recoveryCode,spacing:20){VStack(alignment:.leading,spacing:10){Label(L10n.text("请保存一次性恢复码"),systemImage:"key").font(PencilFont.text(16));Text(model.recoveryCode).font(.body.monospaced()).textSelection(.enabled);Button(L10n.text("我已保存")){model.recoveryCode=""}}.padding(16).background(PetAppearance.surface,in:PencilOutline(radius:8))}
      VStack(alignment:.leading,spacing:20) {
      if !model.authenticated && LocalCompanion.requiresLogin(page:model.selectedTab) {Text(L10n.text("登录后，和朋友的桌宠见面。")).font(PencilFont.text(14));AuthView(model:model).frame(maxWidth:400)} else {
       switch model.selectedTab {
       case 1:PeopleView(model:model)
       case 2:RequestsView(model:model)
       case 3:AgentView(model:model)
       case 4:SettingsView(model:model)
       default:PetShowroomView(courierActive:unlock.started != nil,model:model)
       }
      }
      }
     }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
    }
    }
    Divider()
    bottomNavigation(elapsed:elapsed)
  }.background(PetAppearance.canvas).overlay(PencilOutline(radius:16).stroke(PetAppearance.line.opacity(0.65),lineWidth:1).allowsHitTesting(false)).tint(PetAppearance.accent).frame(minWidth:420,minHeight:560)
   .overlayPreferenceValue(SocialUnlockAnchors.self) { anchors in
    GeometryReader {geometry in
     if unlock.started != nil,!reducedMotion,let source=anchors[.showroom],let requests=anchors[.requests] {
      SocialUnlockCourier(style:model.displayedStyle,elapsed:elapsed,source:geometry[source],requests:geometry[requests])
     }
    }.allowsHitTesting(false)
   }
  }
  .disabled(model.avatarAuthorizationPresented)
  .accessibilityHidden(model.avatarAuthorizationPresented)
  .overlay{if model.avatarAuthorizationPresented{AvatarAuthorizationSheet(model:model)}}
  .onChange(of:model.authenticated){authenticated in
   unlock.authenticatedChanged(authenticated)
   model.selectedTab=PetLinkNavigation.selection(model.selectedTab,authenticated:authenticated)
   if authenticated {beginUnlock(completed:model.googleAuth.state == .completed)}
  }
  .onReceive(model.googleAuth.$state.dropFirst()){state in if state == .completed {beginUnlock(completed:true)}}
  .onChange(of:reducedMotion){reduced in if reduced {unlock.cancel()}}
  .onDisappear{unlock.cancel()}
 }
 private func beginUnlock(completed:Bool){
  guard model.authenticated,completed,!unlock.played else{return}
  unlock.played=true
  guard !reducedMotion else{return}
  model.selectedTab=0
  unlock.started=Date.timeIntervalSinceReferenceDate
  unlock.task=Task { @MainActor in
   try? await Task.sleep(nanoseconds:UInt64(SocialUnlockMotion.duration*1_000_000_000))
   guard !Task.isCancelled else{return};unlock.started=nil
  }
 }
 private func bottomNavigation(elapsed:Double)->some View {
  let fraction=SocialUnlockMotion.agentShift(elapsed:elapsed,reduced:reducedMotion)/52
  let delivered=SocialUnlockMotion.delivered(elapsed:elapsed,reduced:reducedMotion)==1
  return HStack(spacing:0) {
   ForEach(pages.filter{$0.0 != 4},id:\.0) {page in
    let incoming=page.0==2
    let shown = !incoming || (model.authenticated && delivered)
    navigationButton(page).opacity(shown ? 1:0)
     .frame(width:incoming ? (model.authenticated ? 52*fraction:0):52,alignment:.leading).clipped()
     .allowsHitTesting(shown).accessibilityHidden(!shown)
   }
   Spacer(minLength:20)
   navigationButton(pages.first{$0.0==4}!)
  }.padding(.horizontal,12).frame(height:56)
   .background {
    // Final drop targets stay fixed while the Agent button moves right to make room.
    HStack(spacing:0) {
     ForEach(pages.filter{$0.0 != 4},id:\.0) {page in
      Color.clear.frame(width:42,height:44)
       .anchorPreference(key:SocialUnlockAnchors.self,value:.bounds){anchor in
        page.0==2 ? [.requests:anchor]:[:]
       }.frame(width:52,alignment:.leading)
     }
     Spacer(minLength:20)
     Color.clear.frame(width:42,height:44)
    }.padding(.horizontal,12).accessibilityHidden(true).allowsHitTesting(false)
   }
 }
 private func navigationButton(_ page:(Int,String,String))->some View {
  Button {unlock.cancel();if page.0==1{model.closeAvatarChat()}else{model.selectedTab=page.0}} label:{
   Image(systemName:page.2).font(.system(size:21,weight:.light)).frame(width:42,height:44)
    .background(model.selectedTab==page.0 ? PetAppearance.sage:Color.clear,in:PencilOutline(radius:12))
    .overlay(alignment:.topTrailing){let count=page.0==2 ? model.attentionCount:0;if count>0 {Text("\(count)").font(PencilFont.text(10)).padding(3).background(PetAppearance.coral,in:Circle())}}
  }.buttonStyle(.plain).help(page.1).accessibilityLabel(page.1).accessibilityIdentifier("nav-\(page.0)")
   .accessibilityAddTraits(model.selectedTab==page.0 ? .isSelected:[])

 }
}

struct PetHomeView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 var body:some View {
  VStack(alignment:.leading,spacing:24) {
   if let state=model.snapshot {
    HStack(spacing:24){PetArt(style:state.own.style).scaleEffect(1.45).frame(width:165,height:165);VStack(alignment:.leading,spacing:8){Text(model.petLocationLabel).font(PencilFont.text(22));Text(state.own.phase=="home" ? L10n.text("去朋友家坐坐，或留在这里陪你。"):L10n.text("桌宠只有一个位置，回来时会出现在你的桌面。")).font(PencilFont.text(14)).foregroundStyle(PetAppearance.secondary);HStack{Button(L10n.text("挥手")){model.send("wave")};if state.own.phase != "home"{Button(L10n.text("召回")){model.send("recall")}}}.disabled(!model.connected)}}.padding(.vertical,16)
    HStack{Text(L10n.text("装扮")).font(PencilFont.text(16));Spacer();PencilSegments(title:"",selection:Binding(get:{state.own.style},set:{model.send("style",fields:["style":$0])}),options:[(0,L10n.text("青绿")),(1,L10n.text("围巾"))]).disabled(!model.connected)}
    Divider()
    HStack{Text(L10n.text("来访的小伙伴")).font(PencilFont.text(16));Spacer();Text("\(state.pets.filter{$0.ownerID != state.selfID}.count) / 3").font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)}
    let visitors=state.pets.filter{$0.ownerID != state.selfID}
    if visitors.isEmpty {Text(L10n.text("现在没有访客。你可以从联系人中发起串门。")).foregroundStyle(PetAppearance.secondary).padding(.vertical,8)}
    ForEach(visitors){pet in HStack{Image(systemName:"pawprint").foregroundStyle(PetAppearance.accent);Text(pet.nickname);Spacer();if let contact=state.contacts.first(where:{$0.id==pet.ownerID}){Button(L10n.text("聊天")){model.openAvatarChat(contact)}.disabled(model.avatarChatAvailability(contact) != .available)};Button(L10n.text("送客")){model.send("send_home",fields:["pet_id":pet.ownerID])}}.disabled(!model.connected)}
    Divider()
    Toggle(L10n.text("接待新好友"),isOn:Binding(get:{model.accepting},set:{model.setAccepting($0)})).toggleStyle(PencilToggleStyle()).disabled(!model.connected)
    Text(L10n.text("暂停接待不会赶走已经在这里的朋友。")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
   } else {ProgressView(L10n.text("正在确认桌宠位置…"))}
  }
 }
}

@MainActor final class PeoplePresentation:ObservableObject {
 @Published var detailID:String?
 @Published var showAdd=false
 @Published var destructiveContact:V2ContactDTO?
 @Published var blocking=false
}

struct PeopleView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 @StateObject private var presentation=PeoplePresentation()
 private var allContacts:[V2ContactDTO] {model.snapshot?.contacts ?? []}
 private var detailID:String? {reconciledContactDetailID(presentation.detailID,allContactIDs:allContacts.map(\.id))}
 private var contacts:[V2ContactDTO] {
  let q=model.contactSearch.trimmingCharacters(in:.whitespacesAndNewlines)
  return (model.snapshot?.contacts ?? []).filter { (model.contactFilter==0 || $0.trusted) && (q.isEmpty || [$0.nickname,$0.friendID,$0.note].contains{$0.localizedCaseInsensitiveContains(q)}) }
 }
 private func contactStatus(_ contact:V2ContactDTO)->String{
  if !contact.online{return L10n.text("离线")}
  if model.isVisiting(contact){return contact.avatarKeyReady ? L10n.text("来访中 · 可聊天"):L10n.text("来访中 · 未开启聊天")}
  return contact.accepting ? L10n.text("在线 · 尚未来访"):L10n.text("暂停接待")
 }
 var body:some View {
  VStack(alignment:.leading,spacing:18) {
   if detailID==nil {
   VStack(alignment:.leading,spacing:18) {
    HStack{TextField(L10n.text("搜索朋友"),text:$model.contactSearch).textFieldStyle(PencilTextFieldStyle()).accessibilityIdentifier("contact-search");Button(L10n.text("添加好友")){presentation.showAdd.toggle()}}
    if presentation.showAdd {VStack(alignment:.leading){TextField(L10n.text("输入精确好友 ID"),text:$model.friendIDInput).textFieldStyle(PencilTextFieldStyle()).accessibilityIdentifier("friend-id");Button(L10n.text("发送申请")){model.addFriend()}.disabled(!model.connected)}}
    PencilSegments(title:"",selection:$model.contactFilter,options:[(0,L10n.text("全部好友")),(1,L10n.text("私密好友"))])
    if contacts.isEmpty {Text(L10n.text("没有匹配的联系人，添加好友或换一个搜索词。")).foregroundStyle(PetAppearance.secondary).padding(.vertical,16)}
    ForEach(contacts){c in
     HStack(spacing:12) {
      PetArt(style:c.style,size:48).frame(width:58,height:64)
      VStack(alignment:.leading,spacing:5){Text(c.note.isEmpty ? c.nickname:c.note).font(PencilFont.text(18)).lineLimit(1);Text(contactStatus(c)).font(PencilFont.text(12)).foregroundStyle(model.avatarChatAvailability(c) == .available ? PetAppearance.accent:PetAppearance.secondary)}
      Spacer(minLength:4)
      if model.isVisiting(c){Button(L10n.text("送客")){model.send("send_home",fields:["pet_id":c.id])}.disabled(!model.connected)}else{Button(c.autoVisit ? L10n.text("串门"):L10n.text("申请串门")){model.requestVisit(c)}.disabled(!model.canVisit(c))}
      Button{model.openAvatarChat(c)}label:{Image(systemName:"bubble.left.and.bubble.right").font(.system(size:18,weight:.light)).frame(width:33,height:33).foregroundStyle(model.avatarChatAvailability(c) == .available ? PetAppearance.accent:PetAppearance.secondary).background(model.avatarChatAvailability(c) == .available ? PetAppearance.sage:Color.clear,in:PencilOutline(radius:9))}
       .buttonStyle(.plain).disabled(model.avatarChatAvailability(c) != .available).opacity(model.avatarChatAvailability(c) == .available ? 1:0.4)
       .help(model.avatarChatAvailability(c) == .available ? L10n.text("与{0}的 Agent 聊天", c.nickname):model.avatarChatAvailability(c).explanation).accessibilityLabel(L10n.text("与{0}的 Agent 聊天", c.nickname)).accessibilityIdentifier("contact-chat-"+c.id)
      Button {presentation.detailID=presentation.detailID==c.id ? nil:c.id} label:{Image(systemName:"chevron.right")}.buttonStyle(.plain).accessibilityLabel(L10n.text("{0}的详情与权限", c.nickname))
     }
     Divider()
    }
   }.frame(maxWidth:.infinity,alignment:.leading)
   }
   if let c=allContacts.first(where:{$0.id==detailID}) {
    VStack(alignment:.leading,spacing:16) {
     Button(L10n.text("‹ 返回联系人")){presentation.detailID=nil}.buttonStyle(.plain)
     HStack{Spacer();PetArt(style:c.style).scaleEffect(1.15).frame(height:130);Spacer()}
     HStack{Text(c.note.isEmpty ? c.nickname:c.note).font(PencilFont.text(22));Spacer();Button(L10n.text("收起")){presentation.detailID=nil}.buttonStyle(.plain)}
      VStack(alignment:.leading,spacing:12){
       Text(c.friendID).font(.caption.monospaced()).foregroundStyle(PetAppearance.secondary).textSelection(.enabled)
       if let agent=c.agent {Label("\(agentProviderLabel(agent.provider)) · \(agentStateLabel(agent.state))",systemImage:"terminal").font(PencilFont.text(14))}
       Toggle(L10n.text("允许自动来访（私密好友）"),isOn:Binding(get:{c.trusted},set:{model.updatePolicy(c,trusted:$0)}))
       Toggle(L10n.text("分享我的 Agent 状态"),isOn:Binding(get:{c.shareAgent},set:{model.updatePolicy(c,share:$0)}))
       Toggle(L10n.text("始终允许该好友提问"),isOn:Binding(get:{c.allowAvatarAsk},set:{model.updateAvatarPolicy(c,enabled:$0)})).accessibilityIdentifier("contact-auto-answer-"+c.id)
       Text(L10n.text("仅在你的桌宠来访时回答；关闭后，提问需逐次同意。")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary).fixedSize(horizontal:false,vertical:true)
       Text(L10n.text("来访、状态分享和自动问答分别授权，互不联动。")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
       if model.editingNoteContactID==c.id {HStack{TextField(L10n.text("备注"),text:$model.noteDraft).textFieldStyle(PencilTextFieldStyle());Button(L10n.text("保存")){model.saveNote()};Button(L10n.text("取消")){model.editingNoteContactID=nil}}} else {Button(L10n.text("编辑备注")){model.beginNote(c)}}
       HStack{Button(L10n.text("删除好友"),role:.destructive){presentation.blocking=false;presentation.destructiveContact=c};Button(L10n.text("拉黑"),role:.destructive){presentation.blocking=true;presentation.destructiveContact=c}}
      }.toggleStyle(PencilToggleStyle()).disabled(!model.connected)

    }.frame(maxWidth:.infinity,alignment:.leading)
   }
  }.confirmationDialog(presentation.blocking ? L10n.text("拉黑这位好友？"):L10n.text("删除这位好友？"),isPresented:Binding(get:{presentation.destructiveContact != nil},set:{if !$0{presentation.destructiveContact=nil}}),titleVisibility:.visible){Button(presentation.blocking ? L10n.text("拉黑"):L10n.text("删除好友"),role:.destructive){if let c=presentation.destructiveContact{model.remove(c,block:presentation.blocking)};presentation.destructiveContact=nil};Button(L10n.text("取消"),role:.cancel){presentation.destructiveContact=nil}}message:{Text(L10n.text("双方的来访和未完成问答将结束。"))}
 }
}

struct MenuBarPanel:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 let open:(Int)->Void
 let quit:()->Void
 var body:some View {
  VStack(spacing:0) {
   ScrollView {
    VStack(alignment:.leading,spacing:16) {
     HStack{Text("PetLink").font(PencilFont.text(22));Spacer();ConnectionLabel(model:model)}
     if !model.authenticated {HStack{if model.initialAppearanceReady{PetArt(style:model.displayedStyle)};VStack{Text(L10n.text("在家"));Button(L10n.text("挥手")){model.waveCompanion()};Button(L10n.text("换装")){open(0)}}};Button(L10n.text("本地会话")){open(3)};Text(L10n.text("登录后，让桌宠和朋友见面。")).foregroundStyle(PetAppearance.secondary);Button(L10n.text("开启社交")){open(1)}} else {
      HStack(spacing:8){
       if model.initialAppearanceReady{PetArt(style:model.displayedStyle)}
       VStack(alignment:.leading,spacing:8){
        Text(model.profileInfo?.nickname ?? L10n.text("我的桌宠")).font(PencilFont.text(22))
        Text(model.petLocationLabel).font(PencilFont.text(14))
        HStack{Button(L10n.text("挥手")){model.waveCompanion()};Button(L10n.text("召回")){model.send("recall")}.disabled(model.displayedAtHome || !model.connected)}
       }
      }
      if !model.recoveryCode.isEmpty || (!model.credentialWarning.isEmpty && !L10n.notice(model.credentialWarning).contains(L10n.text("未使用钥匙串"))) {
       Button(L10n.text("账号安全事项需要处理")){open(4)}
      }
      PencilFeedback(message:model.operationNotice)
      PencilFeedback(message:model.connected ? "":model.message,size:12)
      if model.attentionCount>0 {
       Divider()
       HStack{Text(L10n.text("待处理")).font(PencilFont.text(17));Spacer();Button(L10n.text("全部")){open(2)}}
       ForEach(Array((model.snapshot?.visitRequests ?? []).prefix(3))){r in
        VStack(alignment:.leading,spacing:8){
         HStack{Text(L10n.text("{0} 想来访", model.contactName(r.guestID)));Spacer();VisitCountdown(deadline:r.expiresAt)}
         HStack{Spacer();Button(L10n.text("接受")){model.respondVisit(r,accept:true)};Button(L10n.text("拒绝")){model.respondVisit(r,accept:false)}}
        }.disabled(!model.connected)
       }
       if (model.snapshot?.friendRequests.count ?? 0)>0 {Button(L10n.text("{0} 条好友申请", model.snapshot?.friendRequests.count ?? 0)){open(2)}}
       if model.pendingAvatarCount>0 {Button(L10n.text("{0} 条分身问答待批准", model.pendingAvatarCount)){open(2)}}
      }
      Divider()
      HStack{Text(L10n.text("在线朋友")).font(PencilFont.text(17));Spacer();Button(L10n.text("全部朋友")){open(1)}}
      let online=(model.snapshot?.contacts ?? []).filter{$0.online}
      if online.isEmpty {Text(L10n.text("朋友们暂时不在线")).foregroundStyle(PetAppearance.secondary)}
      ForEach(Array(online.prefix(3))){c in
       HStack{PetArt(style:c.style).scaleEffect(0.4).frame(width:44,height:44);Text(c.note.isEmpty ? c.nickname:c.note).lineLimit(1);Spacer();Button(c.accepting ? (c.autoVisit ? L10n.text("串门"):L10n.text("申请串门")):L10n.text("暂停接待")){model.requestVisit(c)}.disabled(!model.canVisit(c))}
      }
      if let outgoing=model.snapshot?.outgoingVisits.first {
       HStack{Text(L10n.text("等待 {0} 批准", model.contactName(outgoing.hostID)));Spacer();Button(L10n.text("取消")){model.send("visit_cancel",fields:["visit_id":outgoing.id])}.disabled(!model.connected)}
      }
      if !model.localMode,let visitors=model.snapshot?.pets.filter({$0.ownerID != model.snapshot?.selfID}),!visitors.isEmpty {
       Divider()
       ForEach(visitors){pet in HStack{Text(L10n.text("{0} 正在做客", pet.nickname));Spacer();Button(L10n.text("送客")){model.send("send_home",fields:["pet_id":pet.ownerID])}.disabled(!model.connected)}}
      }
     }
    }.padding(20)
   }
   VStack(spacing:12) {
    Divider()
    if model.authenticated {Toggle(L10n.text("接待新好友"),isOn:Binding(get:{model.accepting},set:{model.setAccepting($0)})).disabled(!model.connected)}
    PetVisibilityButton(pets:model.pets)
    HStack{
     Button(L10n.text("打开主窗口")){open(0)}
     Spacer()
     Menu(L10n.text("更多")) {
      Button(L10n.text("换装与换宠物")){open(0)}
      Button(L10n.text("找回桌宠")){model.pets.recoverAll()}
      Divider()
      Toggle(L10n.text("好友互动"),isOn:Binding(get:{model.friendInteractionEnabled},set:{model.setFriendInteractionEnabled($0)})).toggleStyle(.automatic)
      Button(L10n.text("设置")){open(4)}
      Button(L10n.text("退出"),action:quit)
     }.menuStyle(.borderlessButton).fixedSize()
    }
   }.padding(.horizontal,20).padding(.bottom,16)
  }.frame(width:360).background(PetAppearance.canvas)
   .overlay(PencilOutline(radius:14).stroke(PetAppearance.line.opacity(0.6),lineWidth:1).allowsHitTesting(false))
 }
}
