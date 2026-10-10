// Executed only from source; the build excludes this test from the App bundle.
import assert from 'node:assert/strict';
import http from 'node:http';
import {mkdtemp, rm, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {Readable} from 'node:stream';
import {answerWithRuntime, readRequest} from '../client/Resources/DSHAvatarRuntime.mjs';
const unicodeRequest=Buffer.from(JSON.stringify({question:'你好，桌宠🙂',timeout_ms:5000}));
const unicodeDecoded=await readRequest(Readable.from([...unicodeRequest].map(byte=>Buffer.from([byte]))));
assert.equal(unicodeDecoded.question,'你好，桌宠🙂');
await assert.rejects(()=>readRequest(Readable.from([Buffer.from([0xff])])));
await assert.rejects(()=>readRequest(Readable.from([Buffer.alloc(65537)])),/INVALID_INPUT/);
const root=process.argv[2];
const fixture=await mkdtemp(join(tmpdir(),'petlink-dsh-wire-'));
const captured=[];let mode='answer';
const server=http.createServer(async (req,res)=>{
 let input='';for await(const chunk of req)input+=chunk;
 captured.push(JSON.parse(input));
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 const block=mode==='tool' ? {type:'tool_use',id:'fixture-call',name:'read_file',input:{path:'/unavailable'}}:{type:'text',text:''};
 const events=[['message_start',{type:'message_start',message:{id:'fixture-msg',type:'message',role:'assistant',content:[],model:'deepseek-flash',stop_reason:null,usage:{input_tokens:5,output_tokens:0}}}],['content_block_start',{type:'content_block_start',index:0,content_block:block}]];
 if(mode!=='tool')events.push(['content_block_delta',{type:'content_block_delta',index:0,delta:{type:'text_delta',text:'PETLINK_OK'}}]);
 events.push(['content_block_stop',{type:'content_block_stop',index:0}],['message_delta',{type:'message_delta',delta:{stop_reason:mode==='tool' ? 'tool_use':'end_turn'},usage:{output_tokens:3}}],['message_stop',{type:'message_stop'}]);
 for(const [event,data] of events)res.write('event: '+event+'\ndata: '+JSON.stringify(data)+'\n\n');res.end();
});
try {
 // This child owns its entire credential layer and never reads the user's key.
 process.env.DEEPSEEK_API_KEY='petlink-test-fixture';
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const options={root,question:'Synthetic current question only.',timeoutMs:5000,credentialsPath:join(fixture,'.credentials.yaml'),connection:{baseURL:'http://127.0.0.1:'+server.address().port}};
 const result=await answerWithRuntime(options);assert.equal(result.answer,'PETLINK_OK');assert.equal(captured.length,1);
 assert.deepEqual(captured[0].tools ?? [],[]);assert.equal(captured[0].messages.length,1);assert.equal(captured[0].messages[0].role,'user');assert.equal(captured[0].messages[0].content[0].text,options.question);
 assert.ok(captured[0].system);assert.ok(!JSON.stringify(captured[0]).includes('AGENTS.md'));
 mode='tool';await assert.rejects(()=>answerWithRuntime(options),/TOOL_CALL_REJECTED/);
 console.log('DSH real desktop library transport: empty tools, current question only, tool call rejection PASS');
} finally {server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await rm(fixture,{recursive:true,force:true});}
