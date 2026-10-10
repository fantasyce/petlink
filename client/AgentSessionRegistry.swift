import Foundation
struct AgentSessionRegistry {
 private(set) var events:[String:NormalizedAgentEvent]=[:]
 mutating func receive(_ event:NormalizedAgentEvent,now:Date=Date()){
  guard event.occurredAt<=now.addingTimeInterval(60),event.expiresAt>now else{return}
  let key=event.provider+":"+event.sessionRef
  if let old=events[key],event.sequence<=old.sequence{return}
  events[key]=event
  if events.count>128,let oldest=events.filter({$0.key != key}).min(by:{$0.value.occurredAt<$1.value.occurredAt})?.key{events.removeValue(forKey:oldest)}
 }
 mutating func remove(provider:String,keeping refs:Set<String>){
  events=events.filter{$0.value.provider != provider || refs.contains($0.value.sessionRef)}
 }
 func ordered(now:Date=Date())->[NormalizedAgentEvent]{
  func priority(_ state:PetLinkAgentState)->Int{switch state{case .waiting_approval:return 0;case .failed:return 1;case .completed:return 2;case .working:return 3;case .idle:return 4;default:return 5}}
  return events.values.map{e in e.expiresAt>now ? e:NormalizedAgentEvent(provider:e.provider,sessionRef:e.sessionRef,state:.unknown,sequence:e.sequence,occurredAt:e.occurredAt,expiresAt:e.expiresAt)}.sorted{a,b in let pa=priority(a.state),pb=priority(b.state);if pa != pb{return pa<pb};return a.provider+a.sessionRef < b.provider+b.sessionRef}
 }
}
