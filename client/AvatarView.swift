import SwiftUI

struct AvatarAuthorizationSheet:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 @ObservedObject private var authorization:AvatarAuthorization
 init(model:V2ClientModel){self.model=model;authorization=model.avatarAuthorization}
 var body:some View {
  ZStack {
   Color.black.opacity(0.16).ignoresSafeArea().onTapGesture{if !authorization.isBusy{model.cancelAvatarAuthorization()}}
   VStack(alignment:.leading,spacing:15){
    HStack(spacing:12){Image(systemName:"lock").font(.system(size:25,weight:.light)).foregroundStyle(PetAppearance.accent);Text(L10n.text("开启与好友的\nAgent 聊天")).font(PencilFont.text(21))}
    Text(L10n.text("消息会加密传递。")).font(PencilFont.text(15))
    Text(authorization.hasConsent ? L10n.text("这台 Mac 已授权。继续使用时会读取已保存的密钥，如系统要求验证，再完成验证即可。"):L10n.text("你的密钥保存在这台 Mac 的钥匙串中，私钥不会上传到服务器。"))
     .font(PencilFont.text(15)).fixedSize(horizontal:false,vertical:true)
    Text(L10n.text("好友收到问题后，默认需要确认才会回答。")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
    PencilFeedback(message:authorization.message).accessibilityIdentifier("avatar-authorization-status")
    HStack {
     Button(L10n.text("暂不开启")){model.cancelAvatarAuthorization()}.disabled(authorization.isBusy).keyboardShortcut(.cancelAction)
     Spacer()
     Button(authorization.actionTitle){model.authorizeAvatar()}.disabled(authorization.isBusy).keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("avatar-authorize").pencilFocusTarget("avatar-authorize")
    }.padding(.top,9)
   }.padding(22).frame(maxWidth:360).background(PetAppearance.canvas,in:PencilOutline(radius:16))
    .overlay(PencilOutline(radius:16).stroke(PetAppearance.line,lineWidth:1).allowsHitTesting(false))
    .shadow(color:.black.opacity(0.08),radius:12,y:6).padding(22)
    .accessibilityElement(children:.contain).accessibilityLabel(L10n.text("开启加密聊天"))
  }
 }
}

struct AvatarSettingsView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 @ObservedObject private var authorization:AvatarAuthorization
 init(model:V2ClientModel){self.model=model;authorization=model.avatarAuthorization}
 var body:some View {
  VStack(alignment:.leading,spacing:12){
   Text(L10n.text("数字分身")).font(PencilFont.text(20))
   VStack(alignment:.leading,spacing:12){
    HStack{Text(L10n.text("与好友的 Agent 聊天")).font(PencilFont.text(17));Spacer(minLength:6);Text(authorization.isReady ? L10n.text("已开启"):(authorization.hasConsent ? L10n.text("已授权"):L10n.text("尚未开启"))).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)}
    Text(L10n.text("开启加密聊天，也让好友在你的桌宠来访时向它提问。")).font(PencilFont.text(13)).foregroundStyle(PetAppearance.secondary).fixedSize(horizontal:false,vertical:true)
    if !authorization.isReady {
     HStack{Button(authorization.actionTitle){model.presentAvatarAuthorization()}.disabled(authorization.isBusy).accessibilityIdentifier("settings-avatar-authorize").pencilFocusTarget("settings-avatar-authorize");Spacer();Text(L10n.text("密钥保存在本机钥匙串")).font(PencilFont.text(11)).foregroundStyle(PetAppearance.secondary)}
     PencilFeedback(message:authorization.message,size:12)
    }
    Text(L10n.text("我的回答 Agent")).font(PencilFont.text(15)).padding(.top,3)
    HStack(spacing:7){
     ForEach(AvatarAnswerRuntime.providers,id:\.self){provider in
      Button{model.selectAvatarProvider(provider)}label:{HStack(spacing:3){if authorization.isReady,model.avatarAnswerProvider==provider{Image(systemName:"checkmark").font(.system(size:10))};Text(agentProviderLabel(provider)).font(PencilFont.text(12)).lineLimit(1).minimumScaleFactor(0.8)}}
       .disabled(!authorization.isReady || model.avatarProviderReports[provider]?.supported != true)
       .accessibilityIdentifier("avatar-provider-"+provider).pencilFocusTarget("avatar-provider-"+provider)
     }
    }
    if !authorization.isReady{Text(L10n.text("开启后，选择替你回答的 Agent。")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)}
    else {
     if model.avatarProviderChecking{Text(L10n.text("正在检查可用的 Agent…")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)}
     ForEach(AvatarAnswerRuntime.providers.filter{model.avatarProviderReports[$0]?.supported==false},id:\.self){provider in
      Text(agentProviderLabel(provider)+": "+L10n.notice(model.avatarProviderReports[provider]?.reason ?? "")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary).fixedSize(horizontal:false,vertical:true)
     }
     if model.avatarProviderReports.values.contains(where:{!$0.supported}){Button(L10n.text("重新检查")){model.refreshAvatarProviders()}.disabled(model.avatarProviderChecking)}
    }
   }.padding(15).frame(maxWidth:.infinity,alignment:.leading).background(PetAppearance.surface,in:PencilOutline(radius:11))
    .overlay(PencilOutline(radius:11).stroke(PetAppearance.line.opacity(0.35),lineWidth:1).allowsHitTesting(false))
  }.onAppear{model.refreshAvatarProviders()}
 }
}

struct AvatarRequestsView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 private var pending:[AvatarRelayDTO]{(model.snapshot?.avatarTasks ?? []).filter{$0.task.ownerID==model.snapshot?.selfID && $0.task.state=="pending_approval"}}
 var body:some View {
  VStack(alignment:.leading,spacing:12){
   Text(L10n.text("Agent 提问")).font(PencilFont.text(16))
   if pending.isEmpty{Text(L10n.text("暂无待批准的提问")).foregroundStyle(PetAppearance.secondary).font(PencilFont.text(13))}
   ForEach(pending){relay in
    VStack(alignment:.leading,spacing:10){
     Text(L10n.text("{0} 想向你的 Agent 提问", model.contactName(relay.task.requesterID))).font(PencilFont.text(16))
     Text(L10n.text("由 {0} 回答", agentProviderLabel(model.resolvedAvatarProvider(relay.task.provider)))).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
     HStack{
      Button(L10n.text("允许一次")){model.respondAvatar(relay,accept:true)}.accessibilityIdentifier("avatar-approve-"+relay.id)
      Button(L10n.text("始终允许")){model.respondAvatar(relay,accept:true,remember:true)}.accessibilityIdentifier("avatar-always-approve-"+relay.id)
      Button(L10n.text("拒绝")){model.respondAvatar(relay,accept:false)}.accessibilityIdentifier("avatar-reject-"+relay.id)
     }.disabled(!model.connected || model.avatarResponding.contains(relay.id))
     Text(L10n.text("始终允许仅对这位好友生效，可在联系人详情中关闭。")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary).fixedSize(horizontal:false,vertical:true)
    }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(PetAppearance.surface,in:PencilOutline(radius:10))
   }
   PencilFeedback(message:model.avatarOwnerNotice.status).accessibilityIdentifier("avatar-owner-status")
  }
 }
}

struct AvatarChatView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 @ObservedObject private var authorization:AvatarAuthorization
 init(model:V2ClientModel){self.model=model;authorization=model.avatarAuthorization}
 private var contact:V2ContactDTO?{model.snapshot?.contacts.first{$0.accountID==model.selectedAvatarOwner}}
 private var name:String{contact.map{$0.note.isEmpty ? $0.nickname:$0.note} ?? L10n.text("好友")}
 private var items:[AvatarChatExchange]{model.avatarChat.items(owner:model.selectedAvatarOwner)}
 private var waiting:Bool{model.avatarSubmitting || model.avatarChat.isWaiting(owner:model.selectedAvatarOwner)}
 private var available:Bool{contact.map{model.canAskAvatar($0)} ?? false}
 private var marker:String{items.map{$0.id+":"+$0.request.state+":"+$0.request.status+":"+$0.request.answer}.joined(separator:"|")}
 var body:some View {
  VStack(spacing:0){
   HStack(spacing:10){
    Button{model.closeAvatarChat()}label:{Image(systemName:"chevron.left").font(.system(size:17,weight:.light)).frame(width:24,height:36)}.buttonStyle(.plain).accessibilityLabel(L10n.text("返回联系人")).pencilFocusTarget("chat-back")
    PetArt(style:contact?.style ?? 8,size:42)
    VStack(alignment:.leading,spacing:4){Text(name+L10n.text(" 的 Agent")).font(PencilFont.text(20));Text(available ? L10n.text("正在你家做客"):(contact.map{model.avatarChatAvailability($0).explanation} ?? L10n.text("好友已不在联系人中"))).font(PencilFont.text(12)).foregroundStyle(available ? PetAppearance.accent:PetAppearance.secondary)}
    Spacer(minLength:0)
   }.padding(.horizontal,18).padding(.vertical,15)
   Divider()
   ScrollViewReader{proxy in
    ScrollView{
     LazyVStack(alignment:.leading,spacing:20){
      if items.isEmpty{Text(L10n.text("和 {0} 的 Agent 说点什么吧。", name)).font(PencilFont.text(14)).foregroundStyle(PetAppearance.secondary).frame(maxWidth:.infinity).padding(.top,30)}
      ForEach(items){exchange in
       if !exchange.question.isEmpty{HStack{Spacer(minLength:46);Text(exchange.question).font(PencilFont.text(16)).textSelection(.enabled).padding(13).background(PetAppearance.sage,in:PencilOutline(radius:13))}}
       HStack(alignment:.top,spacing:8){
        PetArt(style:contact?.style ?? 8,size:28)
        VStack(alignment:.leading,spacing:7){
         if !exchange.request.answer.isEmpty {
          Text(exchange.request.answer).font(PencilFont.text(16)).textSelection(.enabled).padding(13).frame(maxWidth:.infinity,alignment:.leading).background(PetAppearance.surface,in:PencilOutline(radius:13))
           .overlay(PencilOutline(radius:13).stroke(PetAppearance.line.opacity(0.35),lineWidth:1).allowsHitTesting(false)).accessibilityIdentifier("avatar-answer")
          Text(L10n.text("由 {0} 回答", agentProviderLabel(exchange.request.provider))).font(PencilFont.text(11)).foregroundStyle(PetAppearance.secondary)
         }else if exchange.isWaiting {
          HStack(spacing:8){ProgressView().controlSize(.small);Text(waitingLabel(exchange)).font(PencilFont.text(13));Spacer(minLength:0);if let relay=model.snapshot?.avatarTasks?.first(where:{$0.id==exchange.id}){Button(L10n.text("取消")){model.cancelAvatar(relay)}.buttonStyle(.plain).font(PencilFont.text(12)).accessibilityIdentifier("avatar-cancel-"+relay.id)}}.padding(12).background(PetAppearance.surface,in:PencilOutline(radius:12))
         }else {Text(L10n.notice(exchange.request.status)).font(PencilFont.text(13)).foregroundStyle(PetAppearance.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("avatar-request-status")}
        }
        Spacer(minLength:4)
       }
      }
      Color.clear.frame(height:1).id("chat-bottom")
     }.padding(18)
    }.onAppear{proxy.scrollTo("chat-bottom",anchor:.bottom)}.onChange(of:marker){_ in proxy.scrollTo("chat-bottom",anchor:.bottom)}
   }
   Divider()
   VStack(alignment:.leading,spacing:8){
    PencilFeedback(message:available ? "":(contact.map{model.avatarChatAvailability($0).explanation} ?? L10n.text("好友已不在联系人中")),size:12)
    HStack(alignment:.bottom,spacing:9){
     AvatarChatInput(text:Binding(get:{model.avatarQuestion},set:{model.avatarQuestion=$0}),enabled:available && !waiting,placeholder:waiting ? L10n.text("收到回答后，可以继续提问"):L10n.text("和 {0} 的 Agent 说点什么…", name),submit:send)
     Button(action:send){Text(L10n.text("发送")).font(PencilFont.text(15)).frame(width:54,height:38).background(PetAppearance.surface,in:PencilOutline()).overlay(PencilOutline().stroke(PetAppearance.line.opacity(0.8),lineWidth:1))}
      .buttonStyle(.plain).disabled(!canSend).opacity(canSend ? 1:0.5).accessibilityIdentifier("avatar-send").pencilFocusTarget("avatar-send")
    }
    HStack{Label(L10n.text("消息已加密"),systemImage:"lock");Spacer();Text(L10n.text("⌘ + Enter 发送"))}.font(PencilFont.text(11)).foregroundStyle(PetAppearance.secondary)
    PencilFeedback(message:model.avatarQuestion.utf8.count>8192 ? L10n.text("内容太长，请缩短后发送。"):"",size:12)
   }.padding(.horizontal,18).padding(.vertical,12)
  }.frame(maxWidth:.infinity,maxHeight:.infinity).background(PetAppearance.canvas)
 }
 private var canSend:Bool{available && !waiting && !model.avatarQuestion.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && model.avatarQuestion.utf8.count<=8192}
 private func send(){if canSend{model.askAvatar()}}
 private func waitingLabel(_ exchange:AvatarChatExchange)->String{switch exchange.request.state{case "submitting":return L10n.text("正在加密发送…");case "pending_approval":return L10n.text("等待 {0} 同意", name);default:return L10n.text("Agent 正在回答…")}}
}
