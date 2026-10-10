import Foundation

enum PetLinkEndpoint {
 static let production="https://api.fantasyce.com:8443/petlink"
 // The shipping profile always uses the domain. Independent development
 // profiles may retain their own endpoint; explicit launch overrides win.
 static func resolve(saved:String?,override:String?=nil,profile:String="default")->String {
  if let override{return override}
  return profile=="default" ? production:(saved ?? production)
 }
 static func isProduction(_ url:URL)->Bool {
  guard url.scheme=="https",url.host=="api.fantasyce.com",url.port==8443,
   url.user==nil,url.password==nil,url.query==nil,url.fragment==nil else{return false}
  return url.path=="/petlink" || url.path=="/petlink/"
 }
}
