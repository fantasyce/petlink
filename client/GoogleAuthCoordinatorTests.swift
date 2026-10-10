import Foundation

@main struct GoogleAuthCoordinatorTests {
 @MainActor static func main() async throws {
  var attempts=0,adopted=0,browserCloseCount=0
  let config=Data(#"{"mode":"google","client_id":"test-client","migration_open":true,"auth_protocol":1}"#.utf8)
  let begin=Data(#"{"attempt_token":"fixture-attempt","nonce":"fixture-nonce","client_id":"test-client"}"#.utf8)
  let complete=Data(#"{"account_id":"account","friend_id":"friend","access_token":"test-access","refresh_token":"test-refresh"}"#.utf8)
  let request:GoogleAuthCoordinator.Request = {path,_,_ in
   if path=="config"{return config};if path=="google/begin"{attempts+=1;return begin}
   if path=="google/complete"{precondition(browserCloseCount>0,"owned browser must close before session exchange finishes")};return complete
  }
  let browser:GoogleAuthCoordinator.OpenBrowser = {url in
   let items=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
   let redirect=items.first{$0.name=="redirect_uri"}!.value!,state=items.first{$0.name=="state"}!.value!
   precondition(items.first{$0.name=="scope"}!.value=="openid email")
   Task{_ = try? await URLSession.shared.data(from:URL(string:redirect+"?state="+state+"&code=fixture-code")!)}
   return true
  }
  let c=GoogleAuthCoordinator(deviceID:"device",request:request,openBrowser:browser,closeBrowser:{browserCloseCount+=1},onSession:{_ in adopted+=1})
  c.nickname="小满"
  c.migrating=true // an earlier migration choice must not hijack normal login
  await c.start(mode:.login)
  precondition(attempts==1 && adopted==1 && browserCloseCount==1)
  precondition(!c.migrating,"normal Google login must leave legacy migration mode")
  let cancelled=GoogleAuthCoordinator(deviceID:"device",request:request,openBrowser:{_ in true},onSession:{_ in adopted+=1})
  let task=Task{await cancelled.start(mode:.login)}
  while cancelled.state != .authorizing {await Task.yield()}
  cancelled.cancel();await task.value
  precondition(adopted==1 && cancelled.state == .idle)
  let link=GoogleAuthCoordinator(deviceID:"device",request:{path,_,_ in
   if path=="config"{return config};if path=="google/begin"{return begin}
   if path=="google/complete"{return Data(#"{"status":"link_confirmation","ticket":"link-ticket","email":"one@example.invalid","nickname":"old","friend_id":"old-friend"}"#.utf8)}
   return complete
  },openBrowser:browser,onSession:{_ in adopted+=1})
  link.legacyAccessToken="old-session-fixture"
  await link.start(mode:.link)
  precondition(link.migrating,"explicit legacy binding must identify itself as migration")
  precondition(link.state == .confirmLink && adopted==1)
  await link.confirm();precondition(adopted==2)
  link.selectMode(.link,legacyToken:"previous-session-fixture")
  link.legacyUsername="old-user";link.legacyPassword="test-password";link.legacyRecovery="test-recovery"
  link.selectMode(.login)
  precondition(!link.migrating && link.legacyAccessToken==nil && link.legacyPassword.isEmpty && link.legacyRecovery.isEmpty && link.notice.isEmpty)
  precondition(link.state == .idle && link.pending==nil,"returning to Google login must discard migration confirmation")
  var continuation:CheckedContinuation<Data,Error>?
  let late=GoogleAuthCoordinator(deviceID:"device",request:{path,_,_ in
   if path=="config"{return config};if path=="google/begin"{return begin}
   if path=="google/complete"{return try await withCheckedThrowingContinuation{continuation=$0}}
   return Data("{}".utf8)
  },openBrowser:browser,onSession:{_ in adopted+=1})
  let lateTask=Task{await late.start(mode:.login)}
  while continuation==nil{await Task.yield()}
  await late.start(mode:.login) // second click while exchanging must not start a flow
  late.cancel();continuation?.resume(returning:complete);await lateTask.value
  precondition(adopted==2 && late.state == .idle)
  let closed=GoogleAuthCoordinator(deviceID:"device",request:{_,_,_ in Data(#"{"mode":"google","client_id":"test-client","migration_open":false,"auth_protocol":1}"#.utf8)},openBrowser:{_ in fatalError("migration opened browser")},onSession:{_ in fatalError("migration adopted")})
  await closed.start(mode:.link);precondition(closed.state == .failed)
  let expired=GoogleAuthCoordinator(deviceID:"device",request:{path,_,_ in
   if path=="config"{return config}
   throw GoogleAuthError.server("UNAUTHORIZED")
  },openBrowser:{_ in fatalError("expired proof opened browser")},onSession:{_ in fatalError("expired proof adopted")})
  expired.legacyAccessToken="expired-fixture"
  await expired.start(mode:.link)
  precondition(expired.legacyAccessToken==nil && expired.state == .failed)
  let unreachable=GoogleAuthCoordinator(deviceID:"test-device",request:{_,_,_ in throw URLError(.cannotConnectToHost)},openBrowser:{_ in fatalError("unreachable login opened browser")},onSession:{_ in fatalError("unreachable login adopted")})
  await unreachable.start(mode:.login)
  precondition(unreachable.state == .failed && unreachable.notice.contains("无法连接登录服务"))
  precondition(GoogleAuthCoordinator.message(GoogleAuthError.serviceUnavailable).contains("登录服务尚未就绪"))
  print("GoogleAuthCoordinatorTests PASS")
 }
}
