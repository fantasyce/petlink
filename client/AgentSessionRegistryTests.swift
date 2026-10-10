import Foundation
@main struct AgentSessionRegistryTests {
 static func main(){
  let now=Date();var registry=AgentSessionRegistry()
  func event(_ provider:String,_ ref:String,_ state:PetLinkAgentState,_ seq:Int64)->NormalizedAgentEvent{.init(provider:provider,sessionRef:ref,state:state,sequence:seq,occurredAt:now,expiresAt:now.addingTimeInterval(30))}
  registry.receive(event("claude","a",.working,1),now:now)
  registry.receive(event("codex","a",.waiting_approval,1),now:now)
  registry.receive(event("deepseek","b",.failed,1),now:now)
  precondition(registry.events.count==3,"provider/session isolation")
  precondition(registry.ordered(now:now).first?.state == .waiting_approval,"approval priority")
  registry.receive(event("claude","a",.completed,0),now:now)
  precondition(registry.events["claude:a"]?.state == .working,"stale event ignored")
  precondition(registry.ordered(now:now.addingTimeInterval(31)).allSatisfy{$0.state == .unknown},"expired never means completed")
  for i in 0..<300 {registry.receive(event("claude",String(i),.idle,1),now:now)}
  precondition(registry.events.count<=128,"bounded history")
  print("Agent session isolation / order / expiry / retention PASS")
 }
}
