import Foundation

/// Owner notices belong to a single task, never to encryption identity readiness.
struct AvatarOwnerNotice {
 private(set) var taskID:String?
 private(set) var status=""
 private var state=""
 mutating func update(_ relays:[AvatarRelayDTO],account:String,device:String) {
  guard let relay=relays.filter({$0.task.ownerID==account && $0.task.ownerDeviceID==device}).max(by:{$0.task.createdAtMS < $1.task.createdAtMS}) else {taskID=nil;state="";status="";return}
  guard taskID != relay.id || state != relay.task.state else{return}
  taskID=relay.id;state=relay.task.state
  switch state {
  case "pending_approval":status=L10n.text("新提问等待你批准")
  case "routed","running":status=L10n.text("已批准，正在由本地 Agent 回答")
  case "completed":status=L10n.text("回答已加密回传")
  case "expired":status=L10n.text("这次提问已过期")
  case "cancelled":status=L10n.text("提问方已取消这次提问")
  case "rejected":status=L10n.text("已拒绝这次提问")
  case "revoked":status=L10n.text("问答已撤销（来访或授权已结束）")
  default:status=L10n.text("这次问答未完成")
  }
 }
 mutating func set(_ id:String,message:String){guard id==taskID,!["expired","revoked","cancelled","rejected"].contains(state) else{return};status=message}
}

/// Requester-only presentation, independent of the owner's execution notices.
struct AvatarRequestState {
 private(set) var taskID:String?
 private(set) var state=""
 private(set) var status=""
 private(set) var answer=""
 private(set) var provider=""
 private var hasResult=false

 mutating func begin(_ id:String) {
  taskID=id;state="submitting";status=L10n.text("正在加密发送问题…");answer="";provider="";hasResult=false
 }
 mutating func update(_ relays:[AvatarRelayDTO],account:String,device:String)->AvatarRelayDTO? {
  let eligible=relays.filter{$0.task.requesterID==account && $0.task.requesterDeviceID==device}
  if taskID==nil {taskID=eligible.max{a,b in a.task.createdAtMS < b.task.createdAtMS}?.id}
  guard let relay=eligible.first(where:{$0.id==taskID}) else{return nil}
  let terminal=["completed","rejected","cancelled","expired","revoked","failed"]
  if terminal.contains(state),state != relay.task.state{return nil}
  if state=="running",["pending_approval","routed"].contains(relay.task.state){return nil}
  if state=="routed",relay.task.state=="pending_approval"{return nil}
  state=relay.task.state
  switch state {
  case "pending_approval":status=L10n.text("问题已加密发送，等待主人批准")
  case "routed","running":status=L10n.text("主人已批准，数字分身正在回答")
  case "rejected":status=L10n.text("对方已拒绝这次提问");answer=""
  case "cancelled":status=L10n.text("这次提问已取消");answer=""
  case "expired":status=L10n.text("请求已过期，请重新提问");answer=""
  case "revoked":status=L10n.text("问答已撤销（来访或授权已结束）");answer=""
  case "failed":status=L10n.text("回答失败，请重新提问");answer=""
  case "completed":
   if !hasResult {status=relay.result==nil ? L10n.text("回答已完成，但加密内容已过期，请重新提问"):L10n.text("正在校验加密回答…")}
  default:status=L10n.text("未知问答状态，请稍后重试")
  }
  return relay
 }
 mutating func fail(_ id:String,message:String) {
  guard id==taskID else{return}
  state="failed";answer="";status=message
 }
 mutating func submissionFailed(_ id:String,message:String) {
  // WebSocket progress can precede a lost POST response. Keep any confirmed
  // server state; only an unconfirmed send needs a retryable presentation.
  guard id==taskID,state=="submitting" else{return}
  state="submission_failed";status=message
 }
 mutating func notice(_ id:String,message:String){guard id==taskID else{return};status=message}
 mutating func complete(_ id:String,answer:String,provider:String,errorCode:String?=nil) {
  guard id==taskID,!["rejected","cancelled","expired","revoked","failed","submission_failed"].contains(state) else{return}
  hasResult=true
  self.provider=provider
  if errorCode != nil {state="completed";self.answer="";status=L10n.text("对方本地 Agent 回答失败，请稍后重新提问");return}
  state="completed";self.answer=answer;status=L10n.text("由 {0} 加密回答", agentProviderLabel(provider))
 }
}
