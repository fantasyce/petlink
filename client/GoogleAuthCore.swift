import Foundation
import CryptoKit
import Security

enum GoogleAuthError:Error,Equatable {case invalidCallback,cancelled,denied,expired,listenerFailed,invalidEndpoint,invalidResponse,serviceUnavailable,server(String)}
enum GooglePKCE {
 static func base64URL(_ data:Data)->String{data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
 static func random()throws->String{var bytes=[UInt8](repeating:0,count:32);guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else{throw GoogleAuthError.listenerFailed};return base64URL(Data(bytes))}
 static func challenge(_ verifier:String)->String{base64URL(Data(SHA256.hash(data:Data(verifier.utf8))))}
}
enum GoogleCallback {
 static func parse(_ data:Data,url:URL,state:String)throws->String{
  guard data.count<=8192,let raw=String(data:data,encoding:.utf8),raw.hasSuffix("\r\n\r\n") else{throw GoogleAuthError.invalidCallback}
  let lines=raw.components(separatedBy:"\r\n"),parts=lines[0].split(separator:" ",omittingEmptySubsequences:false)
  guard parts.count==3,parts[0]=="GET",parts[2]=="HTTP/1.1",parts[1].hasPrefix("/"),!parts[1].hasPrefix("//"),let target=URLComponents(string:String(parts[1])),target.path==url.path,target.fragment==nil else{throw GoogleAuthError.invalidCallback}
  var headers=[String:String]()
  for line in lines.dropFirst() where !line.isEmpty {
   guard let colon=line.firstIndex(of:":") else{throw GoogleAuthError.invalidCallback}
   let key=line[..<colon].lowercased();guard headers[key]==nil else{throw GoogleAuthError.invalidCallback}
   headers[key]=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
  }
  guard headers["host"]=="127.0.0.1:\(url.port ?? 0)",headers["transfer-encoding"]==nil,(headers["content-length"]==nil||headers["content-length"]=="0") else{throw GoogleAuthError.invalidCallback}
  var query=[String:String]()
  for item in target.queryItems ?? []{guard query[item.name]==nil,let value=item.value else{throw GoogleAuthError.invalidCallback};query[item.name]=value}
  guard query["state"]==state,!state.isEmpty else{throw GoogleAuthError.invalidCallback}
  if query["error"] != nil{guard query["code"]==nil else{throw GoogleAuthError.invalidCallback};throw GoogleAuthError.denied}
  guard let code=query["code"],!code.isEmpty,code.utf8.count<=8192 else{throw GoogleAuthError.invalidCallback}
  return code
 }
}
struct GoogleAuthConfig:Decodable {let mode:String;let clientID:String;let migrationOpen:Bool;let authProtocol:Int;enum CodingKeys:String,CodingKey{case mode;case clientID="client_id",migrationOpen="migration_open",authProtocol="auth_protocol"}}
struct GoogleBeginResponse:Decodable {let attemptToken:String;let nonce:String;let clientID:String;enum CodingKeys:String,CodingKey{case nonce;case attemptToken="attempt_token",clientID="client_id"}}
struct GoogleLoginResponse:Decodable {
 let status:String?;let ticket:String?;let accountID:String?;let friendID:String?;let nickname:String?;let email:String?;let accessToken:String?;let refreshToken:String?
 enum CodingKeys:String,CodingKey{case status,ticket,nickname,email;case accountID="account_id",friendID="friend_id",accessToken="access_token",refreshToken="refresh_token"}
}
