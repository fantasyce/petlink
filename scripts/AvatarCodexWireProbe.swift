import Foundation

struct LocalWireRunner:AvatarProcessRunning {
 let endpoint:String
 let home:String
 func run(_ original:AvatarProcessInvocation)throws->AvatarProcessResult {
  guard let url=URL(string:endpoint),url.host=="127.0.0.1",url.scheme=="http" else{throw AvatarAgentError.invalidResponse}
  var args=original.arguments;args.removeLast()
  for value in ["model_provider=\"petlink_qa\"","model_providers.petlink_qa.name=\"PetLink QA\"","model_providers.petlink_qa.base_url=\""+endpoint+"\"","model_providers.petlink_qa.wire_api=\"responses\"","model_providers.petlink_qa.requires_openai_auth=false"]{args += ["-c",value]};args.append("-")
  var environment=original.environment;environment["CODEX_HOME"]=home
  return try AvatarProcessRunner().run(.init(executable:original.executable,arguments:args,environment:environment,timeout:original.timeout,workingDirectory:original.workingDirectory,input:original.input))
 }
}
@main struct AvatarCodexWireProbe {
 static func main(){do{
  let current=try AvatarAnswerRuntime.codexAdapter()
  let adapter=CodexAvatarAdapter(runner:LocalWireRunner(endpoint:CommandLine.arguments[1],home:CommandLine.arguments[2]),version:current.version,executable:current.executable,model:current.model,features:current.features)
  let answer=try adapter.answer(question:"PETLINK_SYNTHETIC_QUESTION",timeout:10)
  guard answer=="PETLINK_OK" else{throw AvatarAgentError.invalidResponse}
  print("Codex native adapter local transport PASS")
 }catch{print("Codex wire probe failed:",error.localizedDescription);exit(1)}}
}
