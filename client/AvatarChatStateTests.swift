import Foundation

@main struct AvatarChatStateTests {
 static func relay(_ id:String,_ owner:String,_ state:String,_ time:Int64=1,_ requester:String="self",_ device:String="device",_ visit:Int64=1)->AvatarRelayDTO {
  AvatarRelayDTO(task:AvatarTaskDTO(id:id,ownerID:owner,requesterID:requester,requesterDeviceID:device,ownerDeviceID:"peer-device",provider:"codex",state:state,visitRevision:visit,policyRevision:1,requestDigest:"digest",resultDigest:nil,createdAtMS:time,expiresAtMS:time+120000,errorCode:nil),request:nil,result:nil,peerKey:nil)
 }
 static func main(){
  precondition(AvatarChatAvailability.resolve(connected:true,online:true,keyReady:true,visiting:true) == .available)
  precondition(AvatarChatAvailability.resolve(connected:true,online:true,keyReady:false,visiting:true) == .notAuthorized)
  precondition(AvatarChatAvailability.resolve(connected:true,online:true,keyReady:true,visiting:false) == .notVisiting)
  precondition(AvatarChatAvailability.resolve(connected:true,online:false,keyReady:true,visiting:true) == .offline)
  precondition(AvatarChatAvailability.resolve(connected:false,online:true,keyReady:true,visiting:true) == .disconnected)
  var chat=AvatarChatHistory()
  chat.setDraft("question a",owner:"a");chat.setDraft("question b",owner:"b")
  precondition(chat.draft(owner:"a")=="question a" && chat.draft(owner:"b")=="question b")
  chat.begin("one",owner:"a",question:"question a")
  precondition(chat.isWaiting(owner:"a") && !chat.isWaiting(owner:"b"))
  _ = chat.update([relay("one","a","running"),relay("foreign","a","running",5,"other"),relay("other-device","a","running",6,"self","else")],account:"self",device:"device")
  precondition(chat.items(owner:"a").count==1)
  chat.begin("two",owner:"b",question:"question b")
  chat.complete("one",answer:"answer a",provider:"codex")
  precondition(chat.items(owner:"a").first?.request.answer=="answer a")
  precondition(chat.visitorBubble(owner:"a",name:"好友 A")?.message=="answer a")
  precondition(chat.visitorBubble(owner:"a",name:"好友 A")?.isAnswer==true)
  precondition(chat.visitorBubble(owner:"b",name:"好友 B")?.isAnswer==false)
  precondition(chat.visitorBubble(owner:"unknown",name:"无聊天")==nil)
  precondition(chat.visitorBubble(owner:"a",name:"好友 A",visitRevision:2)==nil,"a new visit cannot display the previous visit’s answer")
  chat.complete("one",answer:String(repeating:"长回答\n",count:200),provider:"codex")
  let preview=chat.visitorBubble(owner:"a",name:"好友 A")!.message
  precondition(preview.count<=141 && !preview.contains("\n"),"bubble must carry a bounded preview rather than the full transcript")
  precondition(chat.items(owner:"b").first?.request.answer.isEmpty==true,"late peer answer leaked into the current chat")
  chat.clearSentDraft(owner:"a",matching:"question a")
  precondition(chat.draft(owner:"a").isEmpty && chat.draft(owner:"b")=="question b")
  chat.setDraft("next a",owner:"a");chat.clearSentDraft(owner:"a",matching:"old a")
  precondition(chat.draft(owner:"a")=="next a","late send callback erased a newer draft")
  _ = chat.update([relay("two","b","cancelled")],account:"self",device:"device")
  chat.complete("two",answer:"late cancelled answer",provider:"codex")
  precondition(!chat.isWaiting(owner:"b") && chat.items(owner:"b").first?.request.answer.isEmpty==true)
  chat.begin("three",owner:"a",question:"next a");chat.submissionFailed("three",message:"failed to send")
  precondition(!chat.isWaiting(owner:"a"))
  chat.begin("moved",owner:"a",question:"queued",visitRevision:1)
  _ = chat.update([relay("moved","a","running",7,"self","device",2)],account:"self",device:"device")
  precondition(chat.visitorBubble(owner:"a",name:"好友 A",visitRevision:2)?.taskID=="moved","the accepted task's revision supersedes the provisional snapshot revision")
  precondition(chat.visitorBubble(owner:"a",name:"好友 A",visitRevision:1)?.taskID != "moved")
  chat=AvatarChatHistory()
  precondition(chat.items(owner:"a").isEmpty && chat.draft(owner:"a").isEmpty,"account switch must clear private chat memory")
  print("Contact chat eligibility / drafts / task ownership / terminal results / failure recovery PASS")
 }
}
