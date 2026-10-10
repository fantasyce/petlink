import Foundation
import Darwin

@main struct AgentIntegrationTests {
 static func check(_ ok:@autoclosure()->Bool,_ message:String){if !ok(){fatalError(message)}}
 static func main()throws {
  let raw=#"{"provider":"claude","session_id":"secret-local-session","event":"permission_request","sequence":4,"timestamp":"2026-09-16T02:00:00Z"}"#.data(using:.utf8)!
  let event=try AgentEventNormalizer.decode(raw)
  let out=AgentEventNormalizer.normalize(event,now:Date(timeIntervalSince1970:1_789_523_000))
  check(out.state == .waiting_approval,"approval mapping")
  check(!out.sessionRef.contains("secret"),"session ref must be irreversible")
  let leaking=#"{"provider":"claude","session_id":"s","event":"working","sequence":1,"timestamp":"2026-09-16T02:00:00Z","prompt":"private"}"#.data(using:.utf8)!
  do {_ = try AgentEventNormalizer.decode(leaking);fatalError("sensitive extra key accepted")}catch{}
  let unknown=AgentEventNormalizer.normalize(AgentWireEvent(provider:"deepseek",sessionID:"s",event:"future_event",sequence:2,timestamp:Date()))
  check(unknown.state == .unknown,"unknown mapping")
  let cowork="/qa/Claude-3p/local-agent-mode-sessions/account/org/local_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.json"
  check(AgentEventNormalizer.metadataSessionID(provider:"claude",path:cowork)=="local_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","Cowork desktop IDs must be eligible for coarse status sharing")
  check(AgentEventNormalizer.metadataSessionID(provider:"claude",path:"/qa/claude-code-sessions/account/org/local_aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.json") != nil,"Code desktop IDs must use the same sharing rule")
  check(AgentEventNormalizer.metadataSessionID(provider:"claude",path:"/qa/local_invalid.json")==nil,"Invalid metadata identities cannot be shared")
	let fractional=#"{"provider":"deepseek","session_id":"s","event":"completed","sequence":3,"timestamp":"2026-09-16T02:00:00.123Z"}"#.data(using:.utf8)!
	let fractionalEvent=try AgentEventNormalizer.decode(fractional);check(fractionalEvent.provider=="deepseek","fractional RFC3339 timestamp")
	let temp=URL(fileURLWithPath:"/private/tmp/pl-"+UUID().uuidString.prefix(8))
	let run=temp.appendingPathComponent(".codex-managed/run",isDirectory:true);try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
	let socketPath=run.appendingPathComponent("app-test.sock").path;let fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0);check(fd>=0,"create socket");defer{Darwin.close(fd);try? FileManager.default.removeItem(at:temp)}
	var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size);let capacity=MemoryLayout.size(ofValue:address.sun_path);socketPath.withCString{p in withUnsafeMutablePointer(to:&address.sun_path){raw in raw.withMemoryRebound(to:CChar.self,capacity:capacity){_ = strlcpy($0,p,capacity)}}};let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}};check(bound==0,"bind socket");_ = Darwin.chmod(socketPath,0o600)
	let discovered=CodexSocketDiscovery.find(home:temp);check(discovered==URL(fileURLWithPath:socketPath).resolvingSymlinksInPath().path,"discover private socket")
	_ = Darwin.chmod(socketPath,0o644);check(CodexSocketDiscovery.find(home:temp)==nil,"reject broad socket permissions")
  print("agent normalization tests passed")
 }
}
