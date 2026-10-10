import Foundation
import SQLite3

@main struct SessionCompatibilityTests {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let codex=CodexSessionDiscovery(home:root)
  precondition(codex.scan().isEmpty && codex.connectionNotice.isEmpty,"a fresh empty Agent home is normal idle")
  var db:OpaquePointer?;precondition(sqlite3_open(root.appendingPathComponent("state_99.sqlite").path,&db)==SQLITE_OK);defer{sqlite3_close(db)}
  precondition(sqlite3_exec(db,"CREATE TABLE threads (id TEXT)",nil,nil,nil)==SQLITE_OK)
  precondition(codex.scan().isEmpty && !codex.connectionNotice.isEmpty,"an unreadable future schema must be distinguished from no active sessions")
  precondition(sqlite3_exec(db,"DROP TABLE threads; CREATE TABLE threads (id TEXT, rollout_path TEXT, title TEXT, archived INTEGER, updated_at INTEGER, future_field TEXT)",nil,nil,nil)==SQLITE_OK)
  precondition(codex.scan().isEmpty && codex.connected && codex.connectionNotice.isEmpty,"a new database generation with the needed fields remains compatible and clears the error")
  precondition(sqlite3_exec(db,"BEGIN EXCLUSIVE",nil,nil,nil)==SQLITE_OK)
  _=codex.scan()
  precondition(!codex.connected && !codex.connectionNotice.isEmpty && !codex.connectionNotice.contains("PetLink"),"a temporarily locked database must not request a format adaptation")
  precondition(sqlite3_exec(db,"ROLLBACK",nil,nil,nil)==SQLITE_OK)
  precondition(codex.scan().isEmpty && codex.connected && codex.connectionNotice.isEmpty,"a released database must recover automatically")
  var pageStatement:OpaquePointer?;precondition(sqlite3_prepare_v2(db,"SELECT rootpage FROM sqlite_master WHERE name='threads'",-1,&pageStatement,nil)==SQLITE_OK && sqlite3_step(pageStatement)==SQLITE_ROW)
  let page=Int(sqlite3_column_int(pageStatement,0));sqlite3_finalize(pageStatement)
  precondition(sqlite3_exec(db,"INSERT INTO threads VALUES ('fixture','/fixture','fixture',0,1,'extra')",nil,nil,nil)==SQLITE_OK)
  sqlite3_close(db);db=nil
  let database=root.appendingPathComponent("state_99.sqlite"),good=try Data(contentsOf:database)
  let pageSize=Int(good[16])<<8|Int(good[17]);var corrupt=good;corrupt[(page-1)*pageSize]=0xff;try corrupt.write(to:database)
  _=codex.scan();precondition(!codex.connected && !codex.connectionNotice.isEmpty,"a failed row query cannot be reported as a healthy empty database")
  try good.write(to:database);precondition(codex.scan().isEmpty && codex.connected && codex.connectionNotice.isEmpty,"restored database bytes recover automatically")
  let home=root.appendingPathComponent("dsh"),lock=home.appendingPathComponent("sessions/project/session-compat/session.lock"),file=home.appendingPathComponent("storages/session_projcache/sessions/session-compat.json")
  try FileManager.default.createDirectory(at:lock.deletingLastPathComponent(),withIntermediateDirectories:true);try Data().write(to:lock)
  try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
  func metadata(_ version:Int)throws {
   let value:[String:Any]=["version":version,"record":["identity":["formatVersion":4,"createdAt":1000],"rows":["title":["ver":1,"seq":1,"val":"兼容检查"],"turnBoundary":["ver":2,"seq":2,"val":["lastTurn":1,"openTurnStartSeq":1]]]]]
   try JSONSerialization.data(withJSONObject:value).write(to:file,options:.atomic)
  }
  let dsh=DSHDesktopSessionDiscovery(leases:{[.init(lockPath:lock.path,processIdentity:"fixture-owner")]})
  try metadata(7);precondition(dsh.scan().count==1 && dsh.connectionNotice.isEmpty)
  try metadata(8);precondition(dsh.scan().isEmpty && dsh.connectionNotice.contains("PetLink"),"a newer unknown DSH format must request PetLink adaptation, not another DSH upgrade")
  _=dsh.scan();precondition(dsh.connectionNotice.contains("PetLink"),"reusing a rejected cache must preserve the correct upgrade direction")
  try metadata(6);_ = dsh.scan();precondition(dsh.connectionNotice.contains("PetLink"),"an unsupported Desktop cache format must request PetLink adaptation")
  try metadata(7);precondition(dsh.scan().count==1 && dsh.connectionNotice.isEmpty,"a restored compatible format must automatically recover")
  try FileManager.default.removeItem(at:file);_=dsh.scan();precondition(!dsh.connected && !dsh.connectionNotice.isEmpty,"a live writer with unreadable metadata must expose a read failure")
  try metadata(7);precondition(dsh.scan().count==1 && dsh.connectionNotice.isEmpty,"restored writer metadata must clear a read failure")
  print("Session compatibility: empty versus broken schema, newer compatible database, future/old DSH formats, cached issue and recovery PASS")
 }
}
