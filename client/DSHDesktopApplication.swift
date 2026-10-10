import Foundation
import Darwin

enum DSHDesktopApplication {
 static let bundleID="com.deepseek.dsh"
 static func installedURL()->URL? {
  let roots=[URL(fileURLWithPath:"/Applications"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
  for root in roots {
   let preferred=root.appendingPathComponent("DeepSeek Harness.app")
   if version(at:preferred) != nil {return preferred}
   for candidate in (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [] where candidate.pathExtension=="app" {
    if version(at:candidate) != nil {return candidate}
   }
  }
  return nil
 }
 static func version(at url:URL)->String? {
  guard let info=information(at:url),info["CFBundleIdentifier"] as? String==bundleID,
        let executable=executable(at:url),FileManager.default.isExecutableFile(atPath:executable),
        let version=info["CFBundleShortVersionString"] as? String,
        !version.isEmpty,version.utf8.count<=200 else{return nil}
  return version
 }
 static func executable(at url:URL)->String? {
  guard let name=information(at:url)?["CFBundleExecutable"] as? String,!name.isEmpty,!name.contains("/"),name != ".",name != ".." else{return nil}
  return canonicalPath(url.appendingPathComponent("Contents/MacOS/"+name).path)
 }
 static func canonicalPath(_ path:String)->String {
  guard let resolved=realpath(path,nil) else{return URL(fileURLWithPath:path).standardizedFileURL.path}
  defer{free(resolved)};return String(cString:resolved)
 }
 private static func information(at url:URL)->[String:Any]? {
  guard let data=try? Data(contentsOf:url.appendingPathComponent("Contents/Info.plist")),data.count<=65_536 else{return nil}
  return (try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any]
 }
}
