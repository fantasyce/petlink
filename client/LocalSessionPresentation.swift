import Foundation

struct AgentConnectionPresentation {
 let status:String
 let notice:String
 let canRetry:Bool
}

struct LocalSessionItem:Identifiable,Equatable {
 let provider:String
 let ref:String
 let title:String
 var state:PetLinkAgentState
 var updatedAt:Date
 let sourcePath:String?
 var id:String {provider+":"+ref}
}

enum LocalSessionPresentation {
 static func connection(provider:String,tracking:Bool,captured:Int,connected:Bool,installed:Bool,checking:Bool=false,issue:String="")->AgentConnectionPresentation {
  let status=connectionStatus(provider:provider,tracking:tracking,captured:captured,connected:connected,installed:installed)
  guard tracking,!checking else{return .init(status:checking && tracking ? L10n.text("检测中"):status,notice:"",canRetry:false)}
  if !issue.isEmpty{return .init(status:L10n.text("连接异常"),notice:issue,canRetry:true)}
  return .init(status:status,notice:"",canRetry:!installed && !connected && captured==0)
 }
 static func codexThread(ref:String,threads:[String])->String? {
  threads.first{UUID(uuidString:$0) != nil && AgentEventNormalizer.sessionRef(provider:"codex",sessionID:$0)==ref}
 }
 static func visible(watched:[LocalSessionItem],events:[NormalizedAgentEvent],tracking:Bool,now:Date=Date())->[LocalSessionItem] {
  guard tracking else{return []}
  var items=Dictionary(watched.filter{now.timeIntervalSince($0.updatedAt)<120}.map{($0.id,$0)},uniquingKeysWith:{$0.updatedAt>$1.updatedAt ? $0:$1})
  for event in events where event.expiresAt>now && event.occurredAt<=now.addingTimeInterval(10) {
   let key=event.provider+":"+event.sessionRef
   if var item=items[key] {
    guard event.occurredAt>=item.updatedAt else{continue}
    item.state=event.state;item.updatedAt=event.occurredAt;items[key]=item
   }else if event.state == .working || event.state == .waiting_approval {
    items[key]=LocalSessionItem(provider:event.provider,ref:event.sessionRef,title:agentProviderLabel(event.provider)+L10n.text(" 会话"),state:event.state,updatedAt:event.occurredAt,sourcePath:nil)
   }
  }
  return items.values.filter{$0.state == .working || $0.state == .waiting_approval}.sorted{
   if ($0.state == .waiting_approval) != ($1.state == .waiting_approval){return $0.state == .waiting_approval}
   if $0.provider != $1.provider{return $0.provider<$1.provider}
   if $0.title != $1.title{return $0.title.localizedStandardCompare($1.title) == .orderedAscending}
   return $0.id<$1.id
  }
 }
 static func connectionStatus(provider:String,tracking:Bool,captured:Int,connected:Bool,installed:Bool)->String {
  if !tracking{return L10n.text("追踪已关闭")}
  if captured>0{return L10n.text("正在追踪")}
  if connected{return L10n.text("等待活跃会话")}
  if !installed{return L10n.text("未检测到")}
  return L10n.text("等待活跃会话")
 }
}
