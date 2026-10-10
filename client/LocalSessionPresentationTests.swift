import Foundation

@main struct LocalSessionPresentationTests {
 static func main(){
  let now=Date(timeIntervalSince1970:1000)
  let watched=[LocalSessionItem(provider:"codex",ref:"a",title:"修复登录",state:.working,updatedAt:now.addingTimeInterval(-5),sourcePath:"/qa/rollout-a.jsonl")]
  func event(_ ref:String,_ state:PetLinkAgentState,_ time:Double,_ expiry:Double)->NormalizedAgentEvent {
   .init(provider:"codex",sessionRef:ref,state:state,sequence:1,occurredAt:Date(timeIntervalSince1970:time),expiresAt:Date(timeIntervalSince1970:expiry))
  }
  let combined=LocalSessionPresentation.visible(watched:watched,events:[event("a",.waiting_approval,1000,1030),event("expired",.working,900,930)],tracking:true,now:now)
  precondition(combined.count==1 && combined[0].title=="修复登录" && combined[0].state == .waiting_approval,"deduplicate bridge and transcript while keeping the real title and newer status")
  precondition(combined[0].sourcePath=="/qa/rollout-a.jsonl","matching events keep the original navigation target")
  precondition(LocalSessionPresentation.visible(watched:watched,events:[event("a",.completed,1000,1030)],tracking:true,now:now).isEmpty,"a newer terminal event removes a delayed transcript card")
  precondition(LocalSessionPresentation.visible(watched:watched,events:[event("a",.completed,900,1030)],tracking:true,now:now).count==1,"an older terminal event cannot retire a new turn")
  precondition(LocalSessionPresentation.visible(watched:watched,events:[],tracking:false,now:now).isEmpty,"disabled tracking hides all session sources")
  let bridge=LocalSessionPresentation.visible(watched:[],events:[event("opaque-reference",.working,1000,1030)],tracking:true,now:now)
  precondition(bridge.first?.title=="Codex 会话" && bridge.first?.sourcePath==nil,"bridge-only cards never expose a hash or invent a navigation target")
  let uuid="11111111-2222-3333-4444-555555555551"
  let ref=AgentEventNormalizer.sessionRef(provider:"codex",sessionID:uuid)
  precondition(LocalSessionPresentation.codexThread(ref:ref,threads:[uuid])==uuid,"daemon-only cards retain a verified original navigation target")
  precondition(LocalSessionPresentation.codexThread(ref:ref,threads:["invalid"] )==nil,"never turn an opaque ref into a deep link")
  precondition(LocalSessionPresentation.connectionStatus(provider:"codex",tracking:true,captured:1,connected:false,installed:true)=="正在追踪","live transcript capture must not be mislabeled disconnected")
  precondition(LocalSessionPresentation.connectionStatus(provider:"codex",tracking:true,captured:0,connected:false,installed:true)=="等待活跃会话","idle automatic discovery is not a failed connection")
  precondition(LocalSessionPresentation.connectionStatus(provider:"deepseek",tracking:true,captured:0,connected:true,installed:false)=="等待活跃会话","an available connection without an active task is idle, independent of CLI detection")
  precondition(LocalSessionPresentation.connectionStatus(provider:"claude",tracking:false,captured:1,connected:true,installed:true)=="追踪已关闭","explicit off state takes precedence")
  for provider in ["codex","claude","deepseek"] {
   let idle=LocalSessionPresentation.connection(provider:provider,tracking:true,captured:0,connected:false,installed:true)
   let connectedIdle=LocalSessionPresentation.connection(provider:provider,tracking:true,captured:0,connected:true,installed:true)
   precondition(connectedIdle.status==idle.status && !connectedIdle.canRetry && connectedIdle.notice.isEmpty,"provider transport availability must not change the idle activity label")
   precondition(!idle.canRetry && idle.notice.isEmpty,"waiting for an active session must not expose repair controls")
   precondition(!LocalSessionPresentation.connection(provider:provider,tracking:true,captured:2,connected:true,installed:true).canRetry,"healthy tracking must not expose repair controls")
   let problem=LocalSessionPresentation.connection(provider:provider,tracking:true,captured:0,connected:false,installed:true,issue:"状态格式无法读取")
   precondition(problem.canRetry && !problem.notice.isEmpty && problem.status != idle.status,"a real read failure must be actionable and distinct from idle")
   let disabled=LocalSessionPresentation.connection(provider:provider,tracking:false,captured:0,connected:false,installed:true,issue:"旧错误")
   precondition(!disabled.canRetry && disabled.notice.isEmpty,"tracking off must not retain an old repair prompt")
   precondition(!LocalSessionPresentation.connection(provider:provider,tracking:true,captured:0,connected:false,installed:false,checking:true).canRetry,"initial detection must not flash repair controls")
   let checking=LocalSessionPresentation.connection(provider:provider,tracking:true,captured:0,connected:false,installed:true,checking:true,issue:"之前的错误")
   precondition(checking.status=="检测中" && !checking.canRetry && checking.notice.isEmpty,"manual rechecking must temporarily hide old repair actions and notices")
   precondition(LocalSessionPresentation.connection(provider:provider,tracking:true,captured:0,connected:false,installed:false).canRetry,"a missing installation can be checked again after installation")
   precondition(!LocalSessionPresentation.connection(provider:provider,tracking:true,captured:0,connected:true,installed:true).canRetry,"recovery must remove the repair action")
  }
  print("Local session presentation: active-only, title, deduplication, terminal ordering, navigation, connection labels and contextual retry controls PASS")
 }
}
