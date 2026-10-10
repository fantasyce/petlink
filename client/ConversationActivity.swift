import Foundation

struct ConversationActivity {
 private var finished:[String:(CodexConversationSnapshot,Date)]=[:]
 func visible(now:Date=Date())->[String:CodexConversationSnapshot]{
  active.merging(finished.filter{now < $0.value.1}.mapValues{$0.0}){current,_ in current}
 }
 private(set) var active:[String:CodexConversationSnapshot]=[:]
 private var previous:[String:CodexConversationSnapshot]=[:]
 private var completionSeen:[String:String]=[:]
 mutating func receive(_ value:CodexConversationSnapshot,id:String,now:Date=Date())->Bool {
  guard value.updatedAt != nil else{active.removeValue(forKey:id);return false}
  let old=previous[id];previous[id]=value
  let knownCompletion=completionSeen[id]
  if ["completed","ended"].contains(value.state),let token=value.completionID {completionSeen[id]=token}
  let fresh=now.timeIntervalSince(value.updatedAt ?? .distantPast)<120
  if ["working","waiting_approval"].contains(value.state) && fresh {active[id]=value}else{active.removeValue(forKey:id)}
  finished=finished.filter{now < $0.value.1}
  if !["completed","ended"].contains(value.state) {finished.removeValue(forKey:id)}
  guard let old,fresh,["completed","ended"].contains(value.state) else{return false}
  let done=value.completionID.map{$0 != knownCompletion} ?? (old.state=="working")
  if done {finished[id]=(value,now.addingTimeInterval(8))}
  return done && value.state=="completed"
 }
 mutating func remove(_ id:String){active.removeValue(forKey:id);previous.removeValue(forKey:id);finished.removeValue(forKey:id);completionSeen.removeValue(forKey:id)}
}

enum CompletionMotion {
 static func offset(elapsed:Double,enabled:Bool,reduced:Bool)->Double {
  guard enabled,!reduced,elapsed>=0,elapsed<0.9 else{return 0}
  return -10*sin(elapsed / 0.9 * .pi)
 }
}

func conversationBubbleHeight(_ rows:[(String,Bool)],allCollapsed:Bool)->Double {
 guard !allCollapsed else{return 32}
 return min(420,rows.reduce(0.0){$0+($1.1 ? 38:64)}+8)
}
