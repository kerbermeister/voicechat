"""Serve isolated native photo-codec assertions on macOS; no profiles or media upload.

Run this script, open http://127.0.0.1:7374 in Safari17+, read PASS and press Ctrl-C.
Generated images have no personal content. Results are written in a private temp dir.
"""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, shutil, struct, subprocess, tempfile, zlib

def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='voicechat-photo-codecs-') as temp:
        folder = Path(temp)
        def chunk(kind, data):
            return struct.pack('>I',len(data)) + kind + data + struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
        width,height=128,96
        raw=b''.join(b'\0'+b''.join(bytes((240,40,30)) if x<width//2 else bytes((20,80,220)) for x in range(width)) for _ in range(height))
        (folder/'source.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
        subprocess.run(['sips','-s','format','heic',str(folder/'source.png'),'--out',str(folder/'source.heic')],check=True,capture_output=True)
        subprocess.run(['sips','-s','format','jpeg','-z','6000','8000',str(folder/'source.png'),'--out',str(folder/'48mp.jpg')],check=True,capture_output=True)
        shutil.copyfile(root/'apps/client/web/photos.js',folder/'photos.js')
        shutil.copyfile(root/'prototype/fixtures/photo-codecs.html',folder/'index.html')
        class Handler(SimpleHTTPRequestHandler):
            def __init__(self,*args,**kwargs): super().__init__(*args,directory=str(folder),**kwargs)
            def do_POST(self):
                if self.path!='/result': self.send_error(404);return
                length=int(self.headers.get('Content-Length',0))
                if not 0<length<=8192: self.send_error(413);return
                value=json.loads(self.rfile.read(length))
                print(json.dumps(value,ensure_ascii=False),flush=True)
                (folder/'result.json').write_text(json.dumps(value,indent=2))
                self.send_response(204);self.end_headers()
        print('Local assertions: http://127.0.0.1:7374 — no media upload',flush=True)
        ThreadingHTTPServer(('127.0.0.1',7374),Handler).serve_forever()

if __name__=='__main__': main()
