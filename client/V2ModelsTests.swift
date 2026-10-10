import Foundation

@main struct V2ModelsTests {
 static func main()throws{
  precondition(!V2RequestBinding(epoch:1,accountID:"alice").matches(epoch:2,accountID:"bob"),"a late 401 must never refresh or retry under another account")
  precondition(!V2RequestBinding(epoch:1,accountID:"alice").matches(epoch:2,accountID:"alice"),"logout and relogin must invalidate old requests even for the same account")
  precondition(!V2RequestBinding(epoch:1,accountID:"alice").matches(epoch:1,accountID:nil),"logout must discard old authenticated responses")
  precondition(V2RequestBinding(epoch:1,accountID:"alice").matches(epoch:1,accountID:"alice"),"a current request can refresh its own session")
  precondition(canVisitFromUI(connected:true,online:true,accepting:true,phase:"home",pending:false))
  precondition(!canVisitFromUI(connected:false,online:true,accepting:true,phase:"home",pending:false))
  precondition(!canVisitFromUI(connected:true,online:false,accepting:true,phase:"home",pending:false))
  precondition(!canVisitFromUI(connected:true,online:true,accepting:false,phase:"home",pending:false))
  precondition(!canVisitFromUI(connected:true,online:true,accepting:true,phase:"travel",pending:false))
  precondition(!canVisitFromUI(connected:true,online:true,accepting:true,phase:"home",pending:true))
  assert(visitResultLabel("rejected").contains("拒绝"))
  assert(visitResultLabel("expired").contains("过期"))
  assert(visitResultLabel("cancelled").contains("取消"))
  assert(visitResultLabel("completed").contains("结束"))
  assert(!visitResultLabel("future-status").contains("等待"))
  assert(visitErrorLabel("HOST_PAUSED").contains("暂停接待"))
  precondition(normalizedCredentialPaste(" \nABC- 123\r\n")=="ABC- 123")
  let data=Data(#"{"request_id":"x","self_id":"a","own":{"owner_id":"a","nickname":"Alice","location_id":"a","target_id":"","phase":"home","revision":1,"style":0,"wave_sequence":2},"pets":[],"hides":[],"lease_ms":3000,"contacts":[{"account_id":"b","friend_id":"PL-B","nickname":"Bob","note":"","online":true,"trusted":false,"share_agent":false,"auto_visit":true,"agent":{"provider":"codex","session_ref":"opaque","state":"working","sequence":7,"expires_at":"2026-09-16T02:00:00Z"}}],"friend_requests":[],"visit_requests":[],"outgoing_visits":[]}"#.utf8)
  let snapshot=try JSONDecoder.petLink.decode(V2SnapshotDTO.self,from:data)
  precondition(snapshot.contacts[0].style==0,"old servers fall back to the default pet")
  precondition(snapshot.contacts[0].accepting && snapshot.visitHistory==nil,"old server compatibility")
  var payload=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  var contacts=payload["contacts"] as! [[String:Any]];contacts[0]["accepting"]=false;contacts[0]["style"]=9;payload["contacts"]=contacts
  payload["visit_history"]=[["id":"visit-result","guest_id":"a","host_id":"b","status":"rejected","expires_at":"2026-09-29T00:00:00Z"]]
  let updated=try JSONDecoder.petLink.decode(V2SnapshotDTO.self,from:JSONSerialization.data(withJSONObject:payload))
  precondition(updated.contacts[0].style==9,"friend species and outfit decode from the server")
  contacts[0]["style"]=99;payload["contacts"]=contacts
  let invalid=try JSONDecoder.petLink.decode(V2SnapshotDTO.self,from:JSONSerialization.data(withJSONObject:payload))
  precondition(invalid.contacts[0].style==0,"invalid styles retain a safe default")
  precondition(!updated.contacts[0].accepting && updated.visitHistory?.first?.status=="rejected","new pause/result projection")
  precondition(snapshot.selfID=="a"&&snapshot.contacts.first?.autoVisit==true&&snapshot.own.waveSequence==2)
  precondition(snapshot.contacts.first?.agent?.state=="working"&&agentStateLabel("working")=="工作中"&&agentProviderLabel("codex")=="Codex")
  let session=V2Session(accountID:"a",friendID:"PL-A",accessToken:"access",refreshToken:"refresh")
  let encoded=try JSONEncoder().encode(session);let decoded=try JSONDecoder().decode(V2Session.self,from:encoded);precondition(decoded==session)
  print("V2 models: paste normalization, protocol decode, session roundtrip PASS")
 }
}
