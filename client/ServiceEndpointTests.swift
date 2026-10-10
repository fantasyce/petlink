import Foundation

@main struct ServiceEndpointTests {
 static func main(){
  let production="https://api.fantasyce.com:8443/petlink"
  precondition(PetLinkEndpoint.resolve(saved:nil)==production)
  for stale in ["https://192.0.2.44:8443/petlink"," https://retired.example.invalid/petlink/\n"] {
   precondition(PetLinkEndpoint.resolve(saved:stale)==production,"a persisted endpoint must not redirect the default profile away from production")
  }
  for custom in ["http://127.0.0.1:19746","https://example.invalid/petlink","https://192.0.2.44:8443/other"]{
   precondition(PetLinkEndpoint.resolve(saved:custom,profile:"development")==custom)
   precondition(PetLinkEndpoint.resolve(saved:production,override:custom)==custom)
  }
  precondition(PetLinkEndpoint.isProduction(URL(string:production+"/")!))
  for untrusted in ["https://192.0.2.44:8443/petlink",production+"?x=1",production+"#x","https://api.fantasyce.com/petlink","https://api.fantasyce.com:8443/petlink/other","https://user@api.fantasyce.com:8443/petlink"]{
   precondition(!PetLinkEndpoint.isProduction(URL(string:untrusted)!))
  }
  print("ServiceEndpointTests PASS: production routing, overrides and credential destination")
 }
}
