import Foundation

@main struct GoogleLoopbackTests {
 static func main() async throws {
  let a=GoogleLoopback(),b=GoogleLoopback()
  let ua=try await a.start(state:"state-a"),ub=try await b.start(state:"state-b")
  precondition(ua.host=="127.0.0.1" && ua.port != ub.port)
  let session=URLSession(configuration:.ephemeral)
  let wrong=URL(string:ua.absoluteString+"?state=wrong&code=wrong")!
  let (_,response)=try await session.data(from:wrong);precondition((response as? HTTPURLResponse)?.statusCode==400)
  let wait=Task{try await a.waitForCode()}
  let right=URL(string:ua.absoluteString+"?state=state-a&code=verified-code")!
  let (page,ok)=try await session.data(from:right);precondition((ok as? HTTPURLResponse)?.statusCode==200)
  let html=String(decoding:page,as:UTF8.self)
  precondition(html.contains("history.replaceState") && !html.contains("verified-code"),"callback page must clear credential query parameters without echoing the code")
  precondition((ok as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("text/html")==true)
  precondition((ok as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Security-Policy")?.contains("script-src 'sha256-")==true,"only the fixed cleanup script may run")
  let code=try await wait.value;precondition(code=="verified-code")
  let cancelWait=Task{try await b.waitForCode()};b.cancel()
  do{_ = try await cancelWait.value;fatalError("cancel did not finish")}catch{}
  var req=URLRequest(url:ua);req.timeoutInterval=1
  do{_ = try await session.data(for:req);fatalError("listener remained open")}catch{}
  let timed=GoogleLoopback(timeout:0.05);_ = try await timed.start(state:"timeout")
  do{_ = try await timed.waitForCode();fatalError("did not time out")}catch GoogleAuthError.expired{}catch{throw error}
  print("GoogleLoopbackTests PASS")
 }
}
