"""Opt-in native-adapter transport contract; task-owned HTTP and Codex home."""
import http.server
import json
import pathlib
import subprocess
import sys
import tempfile
import threading

captured = []
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        assert self.headers.get('Authorization') is None, 'user credentials reached QA endpoint'
        captured.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        message = {'type': 'message', 'id': 'fixture-message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'PETLINK_OK', 'annotations': []}]}
        events = [
            {'type': 'response.created', 'response': {'id': 'fixture-response', 'object': 'response', 'status': 'in_progress'}},
            {'type': 'response.output_item.added', 'output_index': 0, 'item': {**message, 'content': []}},
            {'type': 'response.output_text.delta', 'item_id': message['id'], 'output_index': 0, 'content_index': 0, 'delta': 'PETLINK_OK'},
            {'type': 'response.output_item.done', 'output_index': 0, 'item': message},
            {'type': 'response.completed', 'response': {'id': 'fixture-response', 'object': 'response', 'status': 'completed', 'output': [message], 'usage': {'input_tokens': 10, 'output_tokens': 2, 'total_tokens': 12}}},
        ]
        for event in events:
            self.wfile.write(('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n').encode())

with tempfile.TemporaryDirectory(prefix='petlink-codex-wire-') as directory:
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        subprocess.run([sys.argv[1], 'http://127.0.0.1:' + str(server.server_port), directory], check=True, timeout=25)
        assert len(captured) == 1
        request = captured[0]
        assert request.get('tools') == [], 'a tool was exposed to the model'
        assert len(request['input']) == 3, 'unexpected prior context'
        projected = json.dumps(request, ensure_ascii=False)
        assert 'PETLINK_SYNTHETIC_QUESTION' in projected
        for forbidden in ['AGENTS.md', 'Available skills', 'SKILL.md', 'conversation_history', 'mcp__', 'Keychain']:
            assert forbidden not in projected, 'host context entered request: ' + forbidden
        print('Codex production adapter: tools empty, no skills/user instructions/history/auth sent to QA PASS')
    finally:
        server.shutdown()
        server.server_close()
        worker.join()
