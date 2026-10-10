import Foundation
import CryptoKit
import Network

// All mutable state is accessed exclusively on queue, including cancellation.
final class GoogleLoopback: @unchecked Sendable {
 private let queue=DispatchQueue(label:"petlink.google-loopback")
 private let timeout:TimeInterval
 private var listener:NWListener?
 private var connections=[ObjectIdentifier:NWConnection]()
 private var startContinuation:CheckedContinuation<URL,Error>?
 private var codeContinuation:CheckedContinuation<String,Error>?
 private var result:Result<String,Error>?
 private var callbackURL:URL?
 private var state=""
 private var started=false
 private var deadline:DispatchWorkItem?
 init(timeout:TimeInterval=300){self.timeout=timeout}
 func start(state:String)async throws->URL{
  try await withTaskCancellationHandler(operation:{
   try await withCheckedThrowingContinuation{continuation in queue.async{ [self] in
    guard !self.started,self.result==nil,!state.isEmpty else{continuation.resume(throwing:GoogleAuthError.cancelled);return}
    self.started=true;self.state=state;self.startContinuation=continuation
    do{
     let path="/callback/"+(try GooglePKCE.random())
     let parameters=NWParameters.tcp
     parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
     let listener=try NWListener(using:parameters);self.listener=listener
     listener.stateUpdateHandler = { [weak self] status in
      guard let self else{return}
      switch status {
      case .ready:
       guard let port=listener.port,let url=URL(string:"http://127.0.0.1:\(port.rawValue)\(path)") else{self.finish(.failure(GoogleAuthError.listenerFailed));return}
       self.callbackURL=url;self.startContinuation?.resume(returning:url);self.startContinuation=nil
      case .failed: self.finish(.failure(GoogleAuthError.listenerFailed))
      default:break
      }
     }
     listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
     let deadline=DispatchWorkItem{[weak self] in self?.finish(.failure(GoogleAuthError.expired))};self.deadline=deadline
     self.queue.asyncAfter(deadline:.now()+self.timeout,execute:deadline)
     listener.start(queue:self.queue)
    }catch{self.finish(.failure(GoogleAuthError.listenerFailed))}
   }}
  },onCancel:{self.cancel()})
 }
 func waitForCode()async throws->String{
  try await withTaskCancellationHandler(operation:{try await withCheckedThrowingContinuation{continuation in queue.async{
   if let result=self.result{continuation.resume(with:result)}else if self.codeContinuation != nil{continuation.resume(throwing:GoogleAuthError.invalidCallback)}else{self.codeContinuation=continuation}
  }}},onCancel:{self.cancel()})
 }
 func cancel(){queue.async{self.finish(.failure(GoogleAuthError.cancelled))}}
 private func finish(_ result:Result<String,Error>){
  guard self.result==nil else{return};self.result=result
  deadline?.cancel();deadline=nil;listener?.stateUpdateHandler=nil;listener?.newConnectionHandler=nil;listener?.cancel();listener=nil
  for connection in connections.values{connection.cancel()};connections.removeAll()
  if let start=startContinuation{startContinuation=nil;switch result{case .failure(let error):start.resume(throwing:error);case .success:start.resume(throwing:GoogleAuthError.invalidCallback)}}
  codeContinuation?.resume(with:result);codeContinuation=nil
 }
 private func accept(_ c:NWConnection){
  guard result==nil,connections.count<4 else{c.cancel();return}
  let id=ObjectIdentifier(c);connections[id]=c;c.start(queue:queue)
  queue.asyncAfter(deadline:.now()+2){[weak self,weak c] in guard let self,let c,self.connections[id] != nil else{return};self.connections.removeValue(forKey:id);c.cancel()}
  read(c,buffer:Data())
 }
 private func read(_ c:NWConnection,buffer:Data){
  c.receive(minimumIncompleteLength:1,maximumLength:8193-buffer.count){[weak self] data,_,ended,error in
   guard let self,self.connections[ObjectIdentifier(c)] != nil else{return}
   var next=buffer;if let data{next.append(data)}
   guard next.count<=8192,error==nil else{self.reply(c,status:400,result:nil);return}
   if next.range(of:Data("\r\n\r\n".utf8)) != nil{
    do{guard let url=self.callbackURL else{throw GoogleAuthError.invalidCallback};let code=try GoogleCallback.parse(next,url:url,state:self.state);self.reply(c,status:200,result:.success(code))}
    catch GoogleAuthError.denied{self.reply(c,status:200,result:.failure(GoogleAuthError.denied))}
    catch{self.reply(c,status:400,result:nil)}
   }else if ended{self.reply(c,status:400,result:nil)}else{self.read(c,buffer:next)}
  }
 }
 private func reply(_ c:NWConnection,status:Int,result:Result<String,Error>?){
  let script="history.replaceState(null, '', '/petlink-google-return');"
  let hash=Data(SHA256.hash(data:Data(script.utf8))).base64EncodedString()
  let body=status==200 ? L10n.text("<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><title>返回 PetLink</title><script>{0}</script><body>正在返回 PetLink。此页面可关闭。</body></html>", script):"Invalid sign-in callback."
  let type=status==200 ? "text/html":"text/plain"
  let policy=status==200 ? "default-src 'none'; script-src 'sha256-\(hash)'; base-uri 'none'; frame-ancestors 'none'":"default-src 'none'"
  let response="HTTP/1.1 \(status) \(status==200 ? "OK":"Bad Request")\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: \(policy)\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
  c.send(content:Data(response.utf8),completion:.contentProcessed{[weak self] _ in
   guard let self else{return};self.connections.removeValue(forKey:ObjectIdentifier(c));c.cancel()
   if let result{self.finish(result)}
  })
 }
}
