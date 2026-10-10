import AppKit
import SwiftUI
import Combine

struct AuthView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 var body:some View {GoogleAuthView(model:model,auth:model.googleAuth)}
}

struct VisitCountdown:View {
 @ObservedObject private var language=AppLocalization.shared
 let deadline:Date
 var body:some View {TimelineView(.periodic(from:.now,by:1)){context in
  let seconds=max(0,Int(ceil(deadline.timeIntervalSince(context.date))))
  Text(seconds>0 ? L10n.text("剩余 {0} 秒", seconds):L10n.text("正在确认申请结果…")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
 }}
}
struct RequestsView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 var body:some View {VStack(alignment:.leading,spacing:12){
  Text(L10n.text("好友申请")).font(PencilFont.text(16))
  ForEach(model.snapshot?.friendRequests ?? []){r in HStack{Text(L10n.text("来自 {0}", model.contactName(r.fromID)));Spacer();Button(L10n.text("接受")){model.respondFriend(r,accept:true)};Button(L10n.text("拒绝")){model.respondFriend(r,accept:false)}}}
  Divider();Text(L10n.text("来访请求")).font(PencilFont.text(16))
  ForEach(model.snapshot?.visitRequests ?? []){r in HStack{VStack(alignment:.leading){Text(L10n.text("{0} 想来访", model.contactName(r.guestID)));VisitCountdown(deadline:r.expiresAt)};Spacer();Button(L10n.text("接受")){model.respondVisit(r,accept:true)};Button(L10n.text("拒绝")){model.respondVisit(r,accept:false)}}}
  ForEach(model.snapshot?.outgoingVisits ?? []){r in HStack{VStack(alignment:.leading){Text(L10n.text("正在等待 {0} 批准", model.contactName(r.hostID)));VisitCountdown(deadline:r.expiresAt)};Spacer();Button(L10n.text("取消")){model.send("visit_cancel",fields:["visit_id":r.id])}}}
  if let latest=model.snapshot?.visitHistory?.first,latest.status != "pending",(model.snapshot?.outgoingVisits.isEmpty ?? true){
   VStack(alignment:.leading,spacing:4){Text(L10n.text("向 {0} 的最近来访申请", model.contactName(latest.hostID))).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary);Text(visitResultLabel(latest.status)).accessibilityIdentifier("visit-result-status")}
  }else if (model.snapshot?.friendRequests.isEmpty ?? true)&&(model.snapshot?.visitRequests.isEmpty ?? true)&&(model.snapshot?.outgoingVisits.isEmpty ?? true)&&model.pendingAvatarCount==0{Text(L10n.text("暂无待处理请求")).foregroundStyle(PetAppearance.secondary).padding(.vertical,12)}
  Divider();AvatarRequestsView(model:model)
  Spacer()
 }}
}

struct AgentView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 var body:some View {VStack(alignment:.leading,spacing:14){AgentStatusPanel(model:model);Spacer()}}
}
struct SettingsView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 var body:some View {VStack(alignment:.leading,spacing:18){
  if model.authenticated {
   if let p=model.profileInfo {
    HStack(spacing:8){
     if model.editingNickname {
      TextField(L10n.text("昵称"),text:$model.nicknameDraft).textFieldStyle(PencilTextFieldStyle()).accessibilityIdentifier("nickname-editor").disabled(model.savingNickname).pencilFocusTarget("nickname-editor")
      Button(model.savingNickname ? L10n.text("保存中…"):L10n.text("保存")){model.saveNickname()}.disabled(model.savingNickname).pencilFocusTarget("nickname-save")
      Button(L10n.text("取消")){model.nicknameDraft=p.nickname;model.nicknameNotice="";model.editingNickname=false}.disabled(model.savingNickname).pencilFocusTarget("nickname-cancel")
     }else{
      Text(p.nickname).font(PencilFont.text(22)).accessibilityIdentifier("profile-nickname")
      Spacer()
      Button(L10n.text("修改昵称")){model.nicknameDraft=p.nickname;model.nicknameNotice="";model.editingNickname=true}.accessibilityIdentifier("edit-nickname").pencilFocusTarget("nickname-edit")
     }
    }
    PencilFeedback(message:model.nicknameNotice)
    Text(L10n.text("好友 ID：{0}", p.friendID)).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary).textSelection(.enabled)
   }
   Toggle(L10n.text("接待新好友"),isOn:Binding(get:{model.accepting},set:{model.setAccepting($0)})).disabled(!model.connected).pencilFocusTarget("settings-accepting")
   Toggle(L10n.text("好友互动"),isOn:Binding(get:{model.friendInteractionEnabled},set:{model.setFriendInteractionEnabled($0)})).accessibilityIdentifier("friend-interaction-toggle").pencilFocusTarget("settings-interaction")
  }else{
   Button(L10n.text("登录 Google 开启社交")){model.selectedTab=1}.pencilFocusTarget("settings-login")
  }
  Divider()
  PencilAppearanceSettings()
  PencilLanguageSettings()
  ConversationPreferences(monitor:model.pets.conversation)
  if model.authenticated{Divider();AvatarSettingsView(model:model)}
  Divider()
  AgentConnectionSettings(coordinator:model.agentCoordinator,conversation:model.pets.conversation)
  if model.authenticated {
   Divider()
   Button(L10n.text("退出登录"),role:.destructive){model.logout()}.pencilFocusTarget("settings-logout")
  }
  Spacer()
 }.onAppear{if !model.editingNickname {model.nicknameDraft=model.profileInfo?.nickname ?? "";model.nicknameNotice=""}}
  .onChange(of:model.profileInfo?.accountID){_ in model.nicknameDraft=model.profileInfo?.nickname ?? "";model.editingNickname=false}
 }
}


@MainActor final class Delegate:NSObject,NSApplicationDelegate,NSWindowDelegate {var model:V2ClientModel!;var window:NSWindow!;var item:NSStatusItem!
 private var uiDefaults:UserDefaults!
 private var preferences:PencilPreferences!
 private let popover=NSPopover()
 private var observation:AnyCancellable?
 private var languageObservation:AnyCancellable?
 func applicationDidFinishLaunching(_ notification:Notification){
  let args=ProcessInfo.processInfo.arguments
  let profile=args.firstIndex(of:"--profile").flatMap{$0+1<args.count ? args[$0+1]:nil} ?? (Bundle.main.object(forInfoDictionaryKey:"PetLinkProfile") as? String) ?? "default"
  let endpoint=args.firstIndex(of:"--endpoint").flatMap{$0+1<args.count ? args[$0+1]:nil}
  PencilFont.register();installMenus();model=V2ClientModel(profile:profile,endpointOverride:endpoint);preferences=model.pets.preferences
  for index in args.indices where args[index]=="--codex-transcript" && index+1<args.count {model.pets.conversation.select(URL(fileURLWithPath:args[index+1]));model.selectedTab=3}
  uiDefaults=UserDefaults(suiteName:"com.fantasyce.petlink."+profile)
  window=NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  window.title="PetLink"+(profile=="default" ? "":" · "+profile)
  window.minSize=NSSize(width:420,height:620)
  window.isReleasedWhenClosed=false
  window.delegate=self
  PencilTitlebar.configure(window)
  window.backgroundColor=NSColor.windowBackgroundColor
  model.pets.openOutfit={[weak self] in self?.model.openOutfitRequested=true;self?.model.selectedTab=0;self?.show()}
  model.returnFromGoogle={[weak self] in self?.show()}
  let client=model!,appearance=preferences!
  window.contentView=NSHostingView(rootView:PencilKeyboardRoot{PencilRoot(preferences:appearance){VStack(spacing:0){PencilTitlebarHost().frame(height:48);WorkspaceView(model:client)}}.ignoresSafeArea(.container,edges:.top)})
  window.center()
  item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
  item.button?.image=NSImage(systemSymbolName:"pawprint.fill",accessibilityDescription:"PetLink")
  item.button?.target=self;item.button?.action=#selector(togglePanel)
  popover.behavior = .transient
  let openPage:(Int)->Void = {[weak self] page in self?.model.selectedTab=page;self?.show()}
  let quitApp:()->Void = {[weak self] in self?.quit()}
  popover.contentViewController=NSHostingController(rootView:PencilRoot(preferences:preferences){MenuBarPanel(model:client,open:openPage,quit:quitApp)})
  popover.contentSize=NSSize(width:360,height:520)
  observation=model.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refreshMenuBadge()}}
  languageObservation=AppLocalization.shared.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.installMenus();self?.refreshMenuBadge();self?.model.objectWillChange.send()}}
  refreshMenuBadge()
  // Normal launches retain an obvious entry point; closing the window leaves
  // the menu bar and pet runtime alive. Explicit background launches stay quiet.
  if !args.contains("--menu-bar") && !uiDefaults.bool(forKey:"main-window-hidden") {show()}
 }
 private func refreshMenuBadge(){
  if model.initialAppearanceReady,let image=MonsterSprites.image(style:model.displayedStyle,frame:0)?.copy() as? NSImage {image.size=NSSize(width:22,height:22);item.button?.image=image}else{item.button?.image=NSImage(systemSymbolName:"pawprint.fill",accessibilityDescription:"PetLink")}
  let count=model.attentionCount
  item.button?.title=count>0 ? " \(count)":""
  item.button?.toolTip=count>0 ? L10n.text("PetLink · {0} 条待处理请求", count):"PetLink · \(L10n.notice(model.connected ? model.petLocationLabel:model.message))"
  item.button?.setAccessibilityLabel(item.button?.toolTip ?? "PetLink")
 }
 @objc private func togglePanel(){
  if popover.isShown{popover.performClose(nil);return}
  // Let the application menu finish tracking before presenting a transient
  // popover; otherwise the menu's dismissal also dismisses the new panel.
  DispatchQueue.main.async{[weak self] in
   guard let self,let button=self.item.button else{return}
   NSApp.activate(ignoringOtherApps:true)
   let available=button.window?.screen?.visibleFrame.height ?? 700
   let content=420+Double(min(self.model.attentionCount,3))*86+Double(min((self.model.snapshot?.contacts ?? []).filter{$0.online}.count,3))*44
   self.popover.contentSize=NSSize(width:360,height:pencilPanelHeight(available:available,content:content))
   self.popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
   self.popover.contentViewController?.view.window?.makeKey()
  }
 }
 func windowWillClose(_ notification:Notification){uiDefaults.set(true,forKey:"main-window-hidden")}
 @objc private func closeWindow(){window.performClose(nil)}
 func installMenus(){let root=NSMenu();let app=NSMenuItem();root.addItem(app);let appMenu=NSMenu();let quick=appMenu.addItem(withTitle:L10n.text("桌宠快捷面板"),action:#selector(togglePanel),keyEquivalent:"p");quick.keyEquivalentModifierMask=[.command,.shift];quick.target=self;let main=appMenu.addItem(withTitle:L10n.text("打开主窗口"),action:#selector(show),keyEquivalent:"0");main.target=self;let close=appMenu.addItem(withTitle:L10n.text("关闭主窗口"),action:#selector(closeWindow),keyEquivalent:"w");close.target=self;appMenu.addItem(.separator());appMenu.addItem(withTitle:L10n.text("退出 PetLink"),action:#selector(quit),keyEquivalent:"q");app.submenu=appMenu;let edit=NSMenuItem();root.addItem(edit);let editMenu=NSMenu(title:L10n.text("编辑"));editMenu.addItem(withTitle:L10n.text("撤销"),action:Selector(("undo:")),keyEquivalent:"z");editMenu.addItem(.separator());editMenu.addItem(withTitle:L10n.text("剪切"),action:#selector(NSText.cut(_:)),keyEquivalent:"x");editMenu.addItem(withTitle:L10n.text("复制"),action:#selector(NSText.copy(_:)),keyEquivalent:"c");editMenu.addItem(withTitle:L10n.text("粘贴"),action:#selector(NSText.paste(_:)),keyEquivalent:"v");editMenu.addItem(withTitle:L10n.text("全选"),action:#selector(NSText.selectAll(_:)),keyEquivalent:"a");edit.submenu=editMenu;NSApp.mainMenu=root}
 @objc func show(){popover.performClose(nil);window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)};@objc func quit(){model?.googleAuth.cancel();model?.disconnect();NSApp.terminate(nil)};func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{show();return true};func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false};func applicationWillTerminate(_ notification:Notification){model?.googleAuth.cancel();model?.disconnect()}}
@main struct Main {@MainActor static func main(){let app=NSApplication.shared;let delegate=Delegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()}}
