import Darwin
import Foundation

@main struct PetLinkAgentEventCLI {
 static func main(){
  let args=CommandLine.arguments
  guard args.count>=3 else{exit(64)}
  let provider=args[1],eventName=args[2]
  // Older running sessions may still invoke the retired helper until restart.
  if provider=="claude" || provider=="deepseek" {exit(0)}
  let input=FileHandle.standardInput.readDataToEndOfFile()
  var session="",sequence=Int64(Date().timeIntervalSince1970*1000)
  if let object=(try? JSONSerialization.jsonObject(with:input)) as? [String:Any]{
   session=(object["session_id"] as? String) ?? (object["sessionId"] as? String) ?? ""
   if let n=object["sequence"] as? NSNumber{sequence=n.int64Value}
  }
  if args.count>=4,!args[3].isEmpty{session=args[3]}
  guard !session.isEmpty else{exit(65)}
  let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime]
  let payload:[String:Any]=["provider":provider,"session_id":session,"event":eventName,"sequence":sequence,"timestamp":formatter.string(from:Date())]
  guard let data=try? JSONSerialization.data(withJSONObject:payload),data.count<=4096 else{exit(65)}
  let fallback=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PetLink/agent-status.sock").path
  let path=ProcessInfo.processInfo.environment["PETLINK_AGENT_SOCKET"] ?? fallback
  guard path.utf8.count<MemoryLayout<sockaddr_un>.size-2 else{exit(66)}
  let fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else{exit(69)};defer{Darwin.close(fd)}
  var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size);let capacity=MemoryLayout.size(ofValue:address.sun_path)
  path.withCString{p in withUnsafeMutablePointer(to:&address.sun_path){raw in raw.withMemoryRebound(to:CChar.self,capacity:capacity){dest in _=strlcpy(dest,p,capacity)}}}
  let connected=withUnsafePointer(to:&address){ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
  guard connected==0 else{exit(69)}
  let sent=data.withUnsafeBytes{Darwin.write(fd,$0.baseAddress,data.count)}
  exit(sent==data.count ? 0:74)
 }
}
