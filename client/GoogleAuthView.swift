import SwiftUI

struct GoogleAuthView:View {
 @ObservedObject private var language=AppLocalization.shared
 @ObservedObject var model:V2ClientModel
 @ObservedObject var auth:GoogleAuthCoordinator
 var body:some View{
  VStack(alignment:.leading,spacing:14){
   Text(auth.migrating ? L10n.text("带回原来的桌宠"):L10n.text("与朋友见面")).font(PencilFont.text(22))
   Text(auth.migrating ? L10n.text("绑定 Google 后，保留原来的好友和桌宠。"):L10n.text("使用 Google 登录，首次使用会创建账号。")).font(PencilFont.text(13)).foregroundStyle(PetAppearance.secondary)
   if auth.state == .confirmLink {
    Text(L10n.text("原账号：{0}", auth.pending?.nickname ?? ""));Text(L10n.text("好友 ID：{0}", auth.pending?.friendID ?? "")).textSelection(.enabled)
    Text(L10n.text("绑定至：{0}", auth.pending?.email ?? "")).textSelection(.enabled)
    Button(L10n.text("确认绑定并保留原账号")){Task{await auth.confirm()}}.buttonStyle(PencilButtonStyle())
    Button(L10n.text("取消")){auth.cancel()}
   }else if auth.state == .confirmTakeover{
    Text(L10n.text("接管后，另一台电脑将退出此账号并隐藏桌宠。"))
    Button(L10n.text("接管到这台电脑")){Task{await auth.confirm()}}.buttonStyle(PencilButtonStyle())
    Button(L10n.text("取消")){auth.cancel()}
   }else{
    if auth.migrating {
     if auth.legacyAccessToken==nil {
      TextField(L10n.text("原用户名"),text:$auth.legacyUsername).textFieldStyle(PencilTextFieldStyle())
      SecureField(L10n.text("原密码（或填写下面的恢复码）"),text:$auth.legacyPassword).textFieldStyle(PencilTextFieldStyle())
      SecureField(L10n.text("原恢复码（与密码二选一）"),text:$auth.legacyRecovery).textFieldStyle(PencilTextFieldStyle())
     }else{Text(L10n.text("将使用这台电脑已有的登录身份进行迁移。"))}
    }
    Button(auth.busy ? L10n.text("正在登录…"):(auth.migrating ? L10n.text("验证旧账号并绑定 Google"):(auth.state == .failed ? L10n.text("重试 Google 登录"):L10n.text("使用 Google 继续")))){if auth.migrating{model.startGoogleLink()}else{model.startGoogleLogin()}}
     .font(.system(size:14,weight:.medium)).buttonStyle(.bordered).controlSize(.large).disabled(auth.busy||model.busy).accessibilityIdentifier("google-login")
    PencilNoticeRegion(isPresented:!auth.notice.isEmpty,identity:auth.notice){Text(L10n.notice(auth.notice)).font(PencilFont.text(13)).foregroundStyle(auth.state == .failed ? PetAppearance.ink:PetAppearance.secondary).accessibilityIdentifier("google-auth-status")}
    if auth.busy{HStack{ProgressView().controlSize(.small);Button(L10n.text("取消登录")){auth.cancel()}}}
    if !auth.busy {Button(auth.migrating ? L10n.text("返回 Google 登录"):L10n.text("使用旧账号迁移…")){auth.selectMode(auth.migrating ? .login:.link,legacyToken:model.googleMigrationToken)}.buttonStyle(.link)}
   }

   PencilNoticeRegion(isPresented:(auth.state == .confirmLink || auth.state == .confirmTakeover) && !auth.notice.isEmpty,identity:auth.notice){Text(L10n.notice(auth.notice)).font(PencilFont.text(13)).accessibilityIdentifier("google-auth-status")}
   Text(L10n.text("Google 密码只在 Google 授权页面输入。PetLink 不读取邮件或云盘。")).font(PencilFont.text(12)).foregroundStyle(PetAppearance.secondary)
  }
 }
}
