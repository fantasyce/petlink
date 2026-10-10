import Foundation

@main struct CodexProbeContractTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let script=root.appendingPathComponent("server.py")
  try Data(#"""
import socket,os,sys,json,struct
os.umask(0o177)
path,mode=sys.argv[1:];srv=socket.socket(socket.AF_UNIX);srv.bind(path);srv.listen(1)
open(path+'.ready','w').close();c,_=srv.accept()
def exact(n):
 d=b''
 while len(d)<n:
  b=c.recv(n-len(d))
  if not b:raise EOFError()
  d+=b
 return d
try:
 header=b''
 while not header.endswith(b'\r\n\r\n'):header+=exact(1)
 c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
 while True:
  h=exact(2);n=h[1]&127
  if n==126:n=struct.unpack('>H',exact(2))[0]
  mask=exact(4);data=exact(n);q=json.loads(bytes(b^mask[i%4] for i,b in enumerate(data)))
  if 'id' not in q:continue
  m=q['method']
  if m=='initialize':result={'userAgent':'isolated-fixture'}
  elif m=='thread/loaded/list':result={'data':[] if mode=='healthy-empty' else ['fixture-thread']}
  else:result={'thread':{'source':'cli','status':{'type':'idle'}}}
  response={'id':q['id'],'result':result}
  if mode=='rpc-error':response={'id':q['id'],'error':{'code':-32601,'message':'unsupported fixture'}}
  if mode=='changed-list' and m=='thread/loaded/list':response['result']={'futureData':[]}
  if mode=='changed-status' and m=='thread/read':response['result']['thread']['status']={'type':'futureActivity'}
  if mode=='changed-flags' and m=='thread/read':response['result']['thread']['status']={'type':'active','activeFlags':{'futureFlag':True}}
  d=json.dumps(response).encode();c.sendall(bytes([129,len(d)])+d if len(d)<126 else bytes([129,126])+struct.pack('>H',len(d))+d)
except (EOFError,BrokenPipeError,ConnectionResetError):pass
finally:c.close();srv.close()
"""#.utf8).write(to:script)
  for mode in ["rpc-error","changed-list","changed-status","changed-flags","healthy-empty"] {
   let socket=root.appendingPathComponent(mode+".sock"),p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/python3");p.arguments=[script.path,socket.path,mode];p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run()
   defer{if p.isRunning{p.terminate();p.waitUntilExit()};try? FileManager.default.removeItem(at:socket);try? FileManager.default.removeItem(atPath:socket.path+".ready")}
   for _ in 0..<300 {if FileManager.default.fileExists(atPath:socket.path+".ready"){break};Thread.sleep(forTimeInterval:0.01)}
   let result=Result{try CodexDaemonProbe.run(socketPath:socket.path,selected:nil,observeAll:true)}
   switch result {
   case .success(let value):if mode != "healthy-empty"{throw NSError(domain:"CodexProbeTest",code:1,userInfo:[NSLocalizedDescriptionKey:"RPC rejection or changed contract must not become a healthy empty connection: "+mode])};precondition(value.threads.isEmpty)
   case .failure(let error):if mode=="healthy-empty"{throw error}
   }
  }
  print("Codex protocol: actual socket RPC rejection, changed list/status and healthy empty listing PASS")
 }
}
