import CryptoKit
import Darwin
import Foundation

enum PetLinkAgentState:String,Codable,CaseIterable {
 case disconnected,idle,working,waiting_approval,completed,failed,unknown
}

struct AgentWireEvent:Codable,Equatable {
 let provider:String
 let sessionID:String
 let event:String
 let sequence:Int64
 let timestamp:Date

 enum CodingKeys:String,CodingKey {case provider;case sessionID="session_id";case event,sequence,timestamp}
}

struct NormalizedAgentEvent:Equatable {
 let provider:String
 let sessionRef:String
 let state:PetLinkAgentState
 let sequence:Int64
 let occurredAt:Date
 let expiresAt:Date
}

enum AgentEventNormalizer {
 static let providers:Set<String> = ["codex","claude","deepseek"]
 static let allowedKeys:Set<String> = ["provider","session_id","event","sequence","timestamp"]
 static func metadataSessionID(provider:String,path:String)->String? {
  if provider=="deepseek" {return path}
  let file=URL(fileURLWithPath:path),id=file.deletingPathExtension().lastPathComponent
  if UUID(uuidString:id) != nil{return id}
  guard provider=="claude",file.pathExtension=="json",file.pathComponents.contains(where:{["claude-code-sessions","local-agent-mode-sessions"].contains($0)}),id.hasPrefix("local_"),UUID(uuidString:String(id.dropFirst(6))) != nil else{return nil}
  return id
 }

 static func decode(_ data:Data)throws->AgentWireEvent {
  guard data.count <= 4096,
        let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
        Set(object.keys).isSubset(of:allowedKeys),
        let provider=object["provider"] as? String,
        let session=object["session_id"] as? String,
        let event=object["event"] as? String,
        let number=object["sequence"] as? NSNumber,
        let timestamp=object["timestamp"] as? String,
		providers.contains(provider),session.count > 0,session.count <= 256,event.count <= 64 else {throw CocoaError(.coderReadCorrupt)}
	let fractional=ISO8601DateFormatter();fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
	let basic=ISO8601DateFormatter()
	guard let date=fractional.date(from:timestamp) ?? basic.date(from:timestamp) else {throw CocoaError(.coderReadCorrupt)}
  return AgentWireEvent(provider:provider,sessionID:session,event:event,sequence:number.int64Value,timestamp:date)
 }

 static func normalize(_ input:AgentWireEvent,now:Date=Date())->NormalizedAgentEvent {
  let raw=input.event.lowercased()
  let state:PetLinkAgentState
  if raw=="disconnected" {state = .disconnected}
  else if ["session_start","idle","ready"].contains(raw){state = .idle}
  else if ["turn_start","tool_start","step_start","working"].contains(raw){state = .working}
  else if ["permission_request","approval_required","waiting_approval"].contains(raw){state = .waiting_approval}
  else if ["turn_end","completed","stop"].contains(raw){state = .completed}
  else if ["error","failed"].contains(raw){state = .failed}
  else {state = .unknown}
  return NormalizedAgentEvent(provider:input.provider,sessionRef:sessionRef(provider:input.provider,sessionID:input.sessionID),state:state,sequence:input.sequence,occurredAt:input.timestamp,expiresAt:max(now,input.timestamp).addingTimeInterval(30))
 }

	static func sessionRef(provider:String,sessionID:String)->String {
		let ref=SHA256.hash(data:Data((provider+"\u{0}"+sessionID).utf8)).map{String(format:"%02x",$0)}.joined()
		return String(ref.prefix(24))
	}
}

enum CodexSocketDiscovery {
 static func find(home:URL,manager:FileManager = .default)->String? {
  let managed=home.appendingPathComponent(".codex-managed",isDirectory:true)
  let control=managed.appendingPathComponent("codex-home/app-server-control/app-server-control.sock")
  let run=managed.appendingPathComponent("run",isDirectory:true)
  let resolvedRun=run.resolvingSymlinksInPath().path
  let resolvedControlDirectory=control.deletingLastPathComponent().resolvingSymlinksInPath().path
  var candidates=[control]
  if let names=try? manager.contentsOfDirectory(atPath:run.path) {
   let dynamic=names.filter{$0.hasPrefix("app-") && $0.hasSuffix(".sock")}.map{run.appendingPathComponent($0)}
   candidates += dynamic.sorted{lhs,rhs in
    let l=(try? manager.attributesOfItem(atPath:lhs.path)[.modificationDate] as? Date) ?? .distantPast
    let r=(try? manager.attributesOfItem(atPath:rhs.path)[.modificationDate] as? Date) ?? .distantPast
    return l > r
   }
  }
  for candidate in candidates {
   let resolved=candidate.resolvingSymlinksInPath()
   guard resolved.path.hasPrefix(resolvedRun+"/") || resolved.path.hasPrefix(resolvedControlDirectory+"/") else{continue}
   guard let attributes=try? manager.attributesOfItem(atPath:resolved.path),
         attributes[.type] as? FileAttributeType == .typeSocket,
         (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
         let permissions=(attributes[.posixPermissions] as? NSNumber)?.intValue,
         permissions & 0o077 == 0 else{continue}
   return resolved.path
  }
  return nil
 }
}
