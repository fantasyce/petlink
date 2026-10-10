import Foundation
@main struct ConversationActivityTests {
 static func main(){
  let now=Date();var model=ConversationActivity()
  var a=CodexConversationSnapshot();a.state="working";a.updatedAt=now
  precondition(!model.receive(a,id:"a",now:now),"initial load never celebrates")
  _ = model.receive(a,id:"b",now:now)
  precondition(model.active.count==2,"two independent active bubbles")
  var waiting=a;waiting.state="waiting_approval"
  _ = model.receive(waiting,id:"waiting",now:now)
  precondition(model.active["waiting"]?.state=="waiting_approval","an official waiting session stays visible while user input is required")
  model.remove("waiting")
  a.state="completed"
  precondition(model.receive(a,id:"a",now:now),"live completion celebrates")
  precondition(model.active.count==1 && model.active["b"] != nil,"completion removes only its bubble")
  precondition(model.visible(now:now)["a"]?.state=="completed","completed summary stays briefly beside other active bubbles")
  precondition(model.visible(now:now.addingTimeInterval(9))["a"]==nil,"completed summary expires automatically")
  precondition(model.visible(now:now.addingTimeInterval(9))["b"] != nil,"expiry does not hide other sessions")
  precondition(!model.receive(a,id:"a",now:now),"duplicate completion never repeats")
  precondition(!model.receive(a,id:"old",now:now),"historical completion never celebrates")
  var ended=CodexConversationSnapshot();ended.state="working";ended.updatedAt=now
  _ = model.receive(ended,id:"dsh",now:now)
  ended.state="ended";ended.completionID="dsh-turn-ended"
  precondition(!model.receive(ended,id:"dsh",now:now),"a DSH turn ending without an outcome must never celebrate success")
  precondition(model.visible(now:now)["dsh"]?.state=="ended" && model.active["dsh"]==nil,"a neutral end briefly remains without claiming success")
  precondition(model.visible(now:now.addingTimeInterval(9))["dsh"]==nil)
  precondition(!model.receive(ended,id:"dsh",now:now),"neutral ends are not replayed")
  var recovered=a;recovered.completionID="turn-1"
  _ = model.receive(recovered,id:"recovery",now:now)
  _ = model.receive(CodexConversationSnapshot(),id:"recovery",now:now)
  precondition(!model.receive(recovered,id:"recovery",now:now),"read recovery must not replay known completion")
  _ = model.receive(CodexConversationSnapshot(),id:"first-failure",now:now)
  precondition(!model.receive(recovered,id:"first-failure",now:now),"first successful read establishes baseline after initial failure")
  a.state="cancelled";_ = model.receive(a,id:"b",now:now)
  precondition(model.active.isEmpty,"cancel removes bubble without celebration")
  a.state="working";a.updatedAt=now.addingTimeInterval(-121);_ = model.receive(a,id:"stale",now:now)
  precondition(model.active.isEmpty,"silence not claimed as active")
  a.updatedAt=now;_ = model.receive(a,id:"new",now:now);model.remove("new")
  precondition(model.active.isEmpty,"unwatch removes bubble")
  precondition(CompletionMotion.offset(elapsed:0.2,enabled:true,reduced:false)<0,"jump moves art upward")
  precondition(CompletionMotion.offset(elapsed:0.45,enabled:true,reduced:false)<(-9),"one jump peaks halfway rather than landing for a second jump")
  precondition(CompletionMotion.offset(elapsed:0.2,enabled:false,reduced:false)==0,"disabled means no motion")
  precondition(CompletionMotion.offset(elapsed:0.2,enabled:true,reduced:true)==0,"reduce motion respected")
  precondition(CompletionMotion.offset(elapsed:2,enabled:true,reduced:false)==0,"jump ends without drift")
  precondition(conversationBubbleHeight([("短进展",false),("短进展",false)],allCollapsed:false)<240,"short progress should not leave a tall blank panel")
  precondition(conversationBubbleHeight(Array(repeating:(String(repeating:"长",count:600),false),count:20),allCollapsed:false)==420,"many bubbles must scroll within bounded height")
  precondition(conversationBubbleHeight([("短进展",false)],allCollapsed:true)<=36,"collapsed bubbles are a tiny count pill")
  print("Multi-session bubbles / isolated completion / replay suppression / expiry / reduced motion PASS")
 }
}
