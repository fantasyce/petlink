// PetLink-owned model call using the unmodified desktop runtime's public exports.
// No Agent, tool, file, session, project, plugin-manager or telemetry is mounted.
import {pathToFileURL, fileURLToPath} from 'node:url';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {homedir} from 'node:os';

export async function answerWithRuntime({root, question, timeoutMs, credentialsPath, connection = {}}) {
  if (typeof question !== 'string' || !question.trim() || Buffer.byteLength(question) > 8192 || !Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 120000) throw new Error('INVALID_INPUT');
  const load = async name => {
    const directory = join(root, name);
    const manifest = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
    if (name !== 'cordis' && manifest.version !== '0.2.0-rc.2') throw new Error('UNSUPPORTED_RUNTIME');
    return import(pathToFileURL(join(directory, 'lib/index.js')).href);
  };
  const {Context} = await load('cordis');
  const llm = await load('dsh-llm');
  const ctx = new Context();
  try {
    const fibers = [];
    const mount = (module, config = {}) => fibers.push(ctx.plugin(module.default ?? module, config));
    mount(llm);
    mount(await load('dsh-credentials-local'), {path: credentialsPath, watch: false});
    mount(await load('dsh-deepseek-account-platform'), {desktopPlatform: 'darwin'});
    mount(await load('dsh-llm-deepseek-api-key'), {...connection, maxTokens: 2048, thinking: 'disabled'});
    mount(await load('dsh-llm-deepseek-account'), {...connection, maxTokens: 2048, thinking: 'disabled'});
    await Promise.all(fibers.map(fiber => fiber.await()));
    for (const name of ['tools', 'agents', 'sessions', 'fs', 'loader', 'storage', 'otel']) {
      if (ctx.get(name) !== undefined) throw new Error('UNEXPECTED_SERVICE');
    }
    const credentials = await load('dsh-credentials');
    const hasApiKey = (await ctx.credentials.resolve(credentials.credentialRef('DEEPSEEK_API_KEY'))) !== undefined;
    const provider = hasApiKey ? 'deepseek-official' : 'deepseek-account';
    const messages = [
      llm.createSystemMessage('You answer for a visiting pet using model knowledge only. No tools, files, commands, web access, user instructions or conversation history are available. Refuse requests requiring these resources. Answer concisely in the user\'s language.'),
      llm.createUserMessage({content: [{type: 'text', text: question}], source: {kind: 'user'}}),
    ];
    let answer = '', stopped = false;
    const stream = await ctx.llm.stream({provider, model: 'deepseek-flash', messages, tools: [], signal: AbortSignal.timeout(timeoutMs)});
    for await (const chunk of stream) {
      if (stopped) throw new Error('INVALID_RESPONSE');
      switch (chunk.type) {
        case 'text-delta': answer += chunk.text; break;
        case 'block-start': if (!['text', 'reasoning'].includes(chunk.blockType)) throw new Error('TOOL_CALL_REJECTED'); break;
        case 'block-end': if (!['text', 'reasoning'].includes(chunk.block?.type)) throw new Error('TOOL_CALL_REJECTED'); break;
        case 'reasoning-delta': case 'usage': break;
        case 'finish':
          if (chunk.reason?.kind !== 'stop') throw new Error('MODEL_REQUEST_FAILED');
          stopped = true; break;
        default: throw new Error('UNKNOWN_STREAM_EVENT');
      }
      if (Buffer.byteLength(answer) > 16384) throw new Error('ANSWER_TOO_LARGE');
    }
    if (!stopped || !answer.trim()) throw new Error('INVALID_RESPONSE');
    return {answer, tools: 0, messages: 2};
  } finally {
    await ctx.fiber.dispose();
  }
}

export async function readRequest(input) {
  const chunks=[];let size=0;
  for await (const chunk of input) {
    size += chunk.length;
    if (size > 65536) throw new Error('INVALID_INPUT');
    chunks.push(chunk);
  }
  return JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(Buffer.concat(chunks)));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const request = await readRequest(process.stdin);
    // The question cannot change the connection, model, credentials or modules.
    const result = await answerWithRuntime({root: process.argv[2], question: request.question, timeoutMs: request.timeout_ms, credentialsPath: join(process.env.DSH_HOME ?? join(homedir(), '.dsh'), '.credentials.yaml')});
    process.stdout.write(JSON.stringify(result));
  } catch {
    process.stdout.write(JSON.stringify({error: 'DSH_ANSWER_FAILED'}));
    process.exitCode = 1;
  }
}
