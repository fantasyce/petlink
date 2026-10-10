import Foundation

enum AvatarChatAvailability:Equatable {
 case available,disconnected,offline,notAuthorized,notVisiting
 static func resolve(connected:Bool,online:Bool,keyReady:Bool,visiting:Bool)->Self {
  if !connected{return .disconnected}
  if !online{return .offline}
  if !visiting{return .notVisiting}
  return keyReady ? .available:.notAuthorized
 }
 var explanation:String {
  switch self {
  case .available:return L10n.text("来访中 · 可聊天")
  case .disconnected:return L10n.text("正在连接")
  case .offline:return L10n.text("好友离线，暂时无法聊天")
  case .notAuthorized:return L10n.text("来访中 · 未开启聊天")
  case .notVisiting:return L10n.text("好友的桌宠尚未来访")
  }
 }
}

struct AvatarChatExchange:Identifiable {
 let id:String,ownerID:String,question:String
 var visitRevision:Int64?
 var request:AvatarRequestState
 var isWaiting:Bool{["submitting","pending_approval","routed","running"].contains(request.state)}
}

/// Chat text stays in this process, separated by friend and encrypted task ID.
/// Logging out replaces this value; nothing here writes a transcript to disk.
struct AvatarChatHistory {
 private var exchanges:[AvatarChatExchange]=[]
 private var drafts:[String:String]=[:]
 func items(owner:String)->[AvatarChatExchange]{exchanges.filter{$0.ownerID==owner}}
 func latest(owner:String)->AvatarChatExchange?{exchanges.last{$0.ownerID==owner}}
 func visitorBubble(owner:String,name:String,visitRevision:Int64?=nil)->VisitorChatBubble? {
  guard let exchange=exchanges.last(where:{$0.ownerID==owner && (visitRevision==nil || $0.visitRevision==visitRevision)}) else{return nil}
  let request=exchange.request
  let answer=request.answer.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
  let message:String
  if !answer.isEmpty {message=String(answer.prefix(140))+(answer.count>140 ? "…":"")}
  else {switch request.state {
   case "submitting":message=L10n.text("正在发送…")
   case "pending_approval":message=L10n.text("等待好友同意")
   case "routed","running":message=L10n.text("Agent 正在回答…")
   default:message=request.status
  }}
  guard !message.isEmpty else{return nil}
  return VisitorChatBubble(taskID:exchange.id,ownerID:owner,name:name,message:message,isAnswer:!answer.isEmpty)
 }
 func isWaiting(owner:String)->Bool{items(owner:owner).contains{$0.isWaiting}}
 func draft(owner:String)->String{drafts[owner] ?? ""}
 mutating func setDraft(_ text:String,owner:String){guard !owner.isEmpty else{return};drafts[owner]=text}
 mutating func clearSentDraft(owner:String,matching question:String){if draft(owner:owner).trimmingCharacters(in:.whitespacesAndNewlines)==question{drafts[owner]=""}}
 mutating func begin(_ id:String,owner:String,question:String,visitRevision:Int64?=nil){
  guard !exchanges.contains(where:{$0.id==id}) else{return}
  var request=AvatarRequestState();request.begin(id)
  exchanges.append(AvatarChatExchange(id:id,ownerID:owner,question:question,visitRevision:visitRevision,request:request))
  // Keep a bounded in-memory conversation without dropping active requests.
  while exchanges.count>100,let old=exchanges.firstIndex(where:{!$0.isWaiting}){exchanges.remove(at:old)}
 }
 mutating func update(_ relays:[AvatarRelayDTO],account:String,device:String)->[AvatarRelayDTO] {
  let eligible=relays.filter{$0.task.requesterID==account && $0.task.requesterDeviceID==device}.sorted{$0.task.createdAtMS < $1.task.createdAtMS}
  var accepted:[AvatarRelayDTO]=[]
  for relay in eligible {
   if !exchanges.contains(where:{$0.id==relay.id}) {
    guard ["pending_approval","routed","running"].contains(relay.task.state) || relay.result != nil else{continue}
    begin(relay.id,owner:relay.task.ownerID,question:"",visitRevision:relay.task.visitRevision)
   }
   guard let index=exchanges.firstIndex(where:{$0.id==relay.id && $0.ownerID==relay.task.ownerID}) else{continue}
   exchanges[index].visitRevision=relay.task.visitRevision
   if let current=exchanges[index].request.update([relay],account:account,device:device){accepted.append(current)}
  }
  return accepted
 }
 mutating func complete(_ id:String,answer:String,provider:String,errorCode:String?=nil){
  guard let index=exchanges.firstIndex(where:{$0.id==id}) else{return}
  exchanges[index].request.complete(id,answer:answer,provider:provider,errorCode:errorCode)
 }
 mutating func fail(_ id:String,message:String){guard let index=exchanges.firstIndex(where:{$0.id==id}) else{return};exchanges[index].request.fail(id,message:message)}
 mutating func submissionFailed(_ id:String,message:String){guard let index=exchanges.firstIndex(where:{$0.id==id}) else{return};exchanges[index].request.submissionFailed(id,message:message)}
 mutating func notice(_ id:String,message:String){guard let index=exchanges.firstIndex(where:{$0.id==id}) else{return};exchanges[index].request.notice(id,message:message)}
}
