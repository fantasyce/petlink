import Darwin
import Foundation

struct CodexProbeResult {let threads:[String];let event:String?;var states:[String:String]=[:]}

enum CodexDaemonProbe {
 static func isUserSource(_ source:Any?)->Bool {
  if let object=source as? [String:Any] {return object["subAgent"]==nil && object["subagent"]==nil}
  return (source as? String)?.lowercased() != "internal"
 }
 static func run(socketPath:String,selected:String?,observeAll:Bool=false)throws->CodexProbeResult {
  let fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else{throw CocoaError(.fileReadUnknown)};defer{Darwin.close(fd)}
  var timeout=timeval(tv_sec:3,tv_usec:0);setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
  var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size);let capacity=MemoryLayout.size(ofValue:address.sun_path);guard socketPath.utf8.count<capacity else{throw CocoaError(.fileReadInvalidFileName)}
  socketPath.withCString{p in withUnsafeMutablePointer(to:&address.sun_path){raw in raw.withMemoryRebound(to:CChar.self,capacity:capacity){_ = strlcpy($0,p,capacity)}}}
  let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}};guard connected==0 else{throw POSIXError(.ECONNREFUSED)}
  let key=Data((0..<16).map{_ in UInt8.random(in:0...255)}).base64EncodedString();let request="GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n";try writeAll(fd,Data(request.utf8));var response=Data();let marker=Data("\r\n\r\n".utf8);while response.count<4 || response.suffix(4) != marker{response.append(try readExact(fd,1));if response.count>8192{throw CocoaError(.fileReadCorruptFile)}};guard String(data:response,encoding:.utf8)?.contains(" 101 ")==true else{throw CocoaError(.fileReadCorruptFile)}
  try sendJSON(fd,["method":"initialize","id":1,"params":["clientInfo":["name":"petlink","title":"PetLink","version":"0.4.0"],"capabilities":[:]]]);_ = try responseFor(fd,id:1)
  try sendJSON(fd,["method":"initialized"]);try sendJSON(fd,["method":"thread/loaded/list","id":2,"params":[:]]);let list=try responseFor(fd,id:2)
  guard let threads=(list["result"] as? [String:Any])?["data"] as? [String] else{throw CocoaError(.fileReadCorruptFile)}
  let targets=observeAll ? Array(threads.prefix(32)):threads.filter{$0==selected}
  var states:[String:String]=[:],excluded=Set<String>()
  for (index,target) in targets.enumerated(){
  try sendJSON(fd,["method":"thread/read","id":index+3,"params":["threadId":target,"includeTurns":false]]);let read=try responseFor(fd,id:index+3)
  guard let thread=(read["result"] as? [String:Any])?["thread"] as? [String:Any] else{throw CocoaError(.fileReadCorruptFile)}
  guard isUserSource(thread["source"]) else{excluded.insert(target);continue}
  guard let status=thread["status"] as? [String:Any],let type=status["type"] as? String,["active","idle","systemError","notLoaded"].contains(type) else{throw CocoaError(.fileReadCorruptFile)}
  guard status["activeFlags"]==nil || status["activeFlags"] is [String] else{throw CocoaError(.fileReadCorruptFile)}
  let flags=status["activeFlags"] as? [String] ?? []
  let event:String
  if flags.contains("waitingOnApproval"){event="waiting_approval"}else if type=="active"{event="working"}else if type=="idle"{event="idle"}else if type=="systemError"{event="failed"}else{event="unknown"}
  states[target]=event
  }
  return CodexProbeResult(threads:threads.filter{!excluded.contains($0)},event:selected.flatMap{states[$0]},states:states)
 }
 private static func sendJSON(_ fd:Int32,_ object:[String:Any])throws{let data=try JSONSerialization.data(withJSONObject:object);try sendFrame(fd,data,opcode:1)}
 private static func responseFor(_ fd:Int32,id:Int)throws->[String:Any]{for _ in 0..<50{let(opcode,data)=try readFrame(fd);if opcode==9{try sendFrame(fd,data,opcode:10);continue};guard opcode==1,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{continue};if (object["id"] as? NSNumber)?.intValue==id{guard object["error"]==nil,object["result"] != nil else{throw CocoaError(.fileReadCorruptFile)};return object}};throw CocoaError(.fileReadCorruptFile)}
 private static func sendFrame(_ fd:Int32,_ payload:Data,opcode:UInt8)throws{var frame=Data([0x80|opcode]);let count=payload.count;if count<126{frame.append(0x80|UInt8(count))}else{frame.append(0x80|126);frame.append(UInt8((count>>8)&255));frame.append(UInt8(count&255))};let mask=(0..<4).map{_ in UInt8.random(in:0...255)};frame.append(contentsOf:mask);frame.append(contentsOf:payload.enumerated().map{$0.element ^ mask[$0.offset%4]});try writeAll(fd,frame)}
 private static func readFrame(_ fd:Int32)throws->(UInt8,Data){let header=try readExact(fd,2);let opcode=header[0]&0x0f;var length=Int(header[1]&0x7f);if length==126{let ext=try readExact(fd,2);length=Int(ext[0])<<8|Int(ext[1])}else if length==127{let ext=try readExact(fd,8);length=ext.reduce(0){$0<<8|Int($1)}};guard length<=1_048_576 else{throw CocoaError(.fileReadTooLarge)};let masked=header[1]&0x80 != 0;let mask=masked ? [UInt8](try readExact(fd,4)):[];var payload=try readExact(fd,length);if masked{for i in payload.indices{payload[i]^=mask[i%4]}};return(opcode,payload)}
 private static func writeAll(_ fd:Int32,_ data:Data)throws{try data.withUnsafeBytes{raw in var sent=0;while sent<data.count{let n=Darwin.write(fd,raw.baseAddress!.advanced(by:sent),data.count-sent);if n<=0{throw POSIXError(.EPIPE)};sent+=n}}}
 private static func readExact(_ fd:Int32,_ count:Int)throws->Data{var data=Data(count:count);let got=try data.withUnsafeMutableBytes{raw->Int in var total=0;while total<count{let n=Darwin.read(fd,raw.baseAddress!.advanced(by:total),count-total);if n<=0{throw POSIXError(.ECONNRESET)};total+=n};return total};return data.prefix(got)}
}
