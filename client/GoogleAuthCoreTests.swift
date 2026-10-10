import Foundation

@main struct GoogleAuthCoreTests {
 static func main() throws {
  let vector="dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  precondition(GooglePKCE.challenge(vector)=="E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  let a=try GooglePKCE.random(),b=try GooglePKCE.random()
  precondition(a.count==43 && a != b)
  let url=URL(string:"http://127.0.0.1:12345/callback/abcdefghijklmnopqrstuv")!
  let valid="GET /callback/abcdefghijklmnopqrstuv?state=state-one&code=hello HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n"
  let code=try GoogleCallback.parse(Data(valid.utf8),url:url,state:"state-one")
  precondition(code=="hello")
  for raw in [valid.replacingOccurrences(of:"state-one",with:"wrong"),valid.replacingOccurrences(of:"&code=hello",with:"&code=hello&code=other"),valid.replacingOccurrences(of:"&code=hello",with:"&code=hello&error=denied"),valid.replacingOccurrences(of:"Host: 127.0.0.1:12345",with:"Host: attacker.invalid"),valid.replacingOccurrences(of:"GET ",with:"POST ")] {
   do {_ = try GoogleCallback.parse(Data(raw.utf8),url:url,state:"state-one");fatalError("invalid callback accepted")}catch{}
  }
  print("GoogleAuthCoreTests PASS")
 }
}
