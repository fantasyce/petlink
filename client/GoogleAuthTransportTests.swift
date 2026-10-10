import Foundation

@main struct GoogleAuthTransportTests {
 @MainActor static func main(){
  for s in ["https://attacker.invalid","https://192.0.2.44:8443/petlink@attacker.invalid","http://127.0.0.1:9999","https://192.0.2.44:8443/petlink?next=other"]{precondition(!GoogleAuthTransport.trusted(URL(string:s)!,profile:"default"))}
  precondition(GoogleAuthTransport.trusted(URL(string:"https://api.fantasyce.com:8443/petlink")!,profile:"default"),"production domain must be trusted")
  precondition(!GoogleAuthTransport.trusted(URL(string:"https://192.0.2.44:8443/petlink")!,profile:"default"),"IP endpoints must not receive production OAuth credentials")
  for s in ["https://api.fantasyce.com:8443/petlink@attacker.invalid","https://api.fantasyce.com.attacker.invalid:8443/petlink","https://api.fantasyce.com:8443/petlink?next=other","http://api.fantasyce.com:8443/petlink"]{precondition(!GoogleAuthTransport.trusted(URL(string:s)!,profile:"default"))}
  precondition(GoogleAuthTransport.trusted(URL(string:"http://127.0.0.1:9999")!,profile:"qa-google"))
  let missing=HTTPURLResponse(url:URL(string:"http://127.0.0.1:9999")!,statusCode:404,httpVersion:nil,headerFields:nil)!
  do{_ = try GoogleAuthTransport.response(data:Data(),response:missing);preconditionFailure("404 accepted")}catch{precondition((error as? GoogleAuthError) == .serviceUnavailable)}
  print("GoogleAuthTransportTests PASS")
 }
}
