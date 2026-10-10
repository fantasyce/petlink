import Foundation

final class GoogleNoRedirect:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}
@MainActor final class GoogleAuthTransport {
 private let session=URLSession(configuration:.ephemeral,delegate:GoogleNoRedirect(),delegateQueue:nil)
 static func trusted(_ endpoint:URL,profile:String)->Bool{
  guard endpoint.user==nil,endpoint.password==nil,endpoint.query==nil,endpoint.fragment==nil else{return false}
  if PetLinkEndpoint.isProduction(endpoint){return true}
  return profile != "default" && endpoint.scheme=="http" && endpoint.host=="127.0.0.1" && endpoint.port != nil
 }
 func request(endpoint:URL,profile:String,path:String,body:[String:Any]?,token:String?)async throws->Data{
  guard Self.trusted(endpoint,profile:profile) else{throw GoogleAuthError.invalidEndpoint}
  var req=URLRequest(url:endpoint.appendingPathComponent("v2/auth").appendingPathComponent(path));req.httpMethod=body==nil ? "GET":"POST";req.timeoutInterval=15
  if let body{req.httpBody=try JSONSerialization.data(withJSONObject:body);req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.setValue(UUID().uuidString,forHTTPHeaderField:"X-Request-ID")}
  if let token{req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
  let(data,response)=try await session.data(for:req)
  return try Self.response(data:data,response:response)
 }
 static func response(data:Data,response:URLResponse)throws->Data{
  guard data.count<=65536,let http=response as? HTTPURLResponse else{throw GoogleAuthError.invalidResponse}
  if http.statusCode==404 {throw GoogleAuthError.serviceUnavailable}
  guard (200..<300).contains(http.statusCode) else{
   struct Failure:Decodable{let code:String}
   throw GoogleAuthError.server((try? JSONDecoder().decode(Failure.self,from:data).code) ?? "AUTH_FAILED")
  }
  return data
 }
}
