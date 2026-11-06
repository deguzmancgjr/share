#!/usr/bin/env python3
"""
APT GHOSTFIRE Data Exfiltration Receiver (Scenario 4)
Listens on TCP port 8000 and records exfiltrated files with SHA-256 validation.
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import hashlib
import os

PORT = 8000
STORAGE_DIR = "/opt/cydex/exfil"

os.makedirs(STORAGE_DIR, exist_ok=True)

class ExfiltrationHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        filename = self.headers.get('X-Filename', 'exfiltrated_data.bin')
        filepath = os.path.join(STORAGE_DIR, filename)

        with open(filepath, 'wb') as f:
            f.write(post_data)

        file_hash = hashlib.sha256(post_data).hexdigest()

        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(f"OK: Received {filename} | SHA256: {file_hash}\n".encode())

        print(f"\n[+] EXFILTRATION DETECTED!")
        print(f"    Source IP  : {self.client_address[0]}")
        print(f"    Filename   : {filepath}")
        print(f"    Size       : {len(post_data)} bytes")
        print(f"    SHA-256    : {file_hash}\n")

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"APT GHOSTFIRE C2 & Staging Server Active\n")

if __name__ == '__main__':
    print(f"[*] APT GHOSTFIRE Exfiltration Server listening on 0.0.0.0:{PORT}...")
    server = HTTPServer(('0.0.0.0', PORT), ExfiltrationHandler)
    server.serve_forever()
