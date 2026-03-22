#!/usr/bin/env python3
"""
Proxmox インストール完了 webhook サーバー
インストール完了後に dnsmasq の PXE を無効化する
URL: POST/GET http://192.168.210.55:9000/webhook/done/<mac(コロンなし)>
"""
import http.server
import subprocess
import re
import os

DNSMASQ_INSTALLED_CONF = "/etc/dnsmasq.d/installed.conf"


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self._handle()

    def do_GET(self):
        self._handle()

    def _handle(self):
        match = re.match(r"/webhook/done/([0-9a-fA-F]{12})$", self.path)
        if match:
            mac_raw = match.group(1).lower()
            mac = ":".join(mac_raw[i:i+2] for i in range(0, 12, 2))
            self._disable_pxe(mac)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")
            print(f"[webhook] インストール完了: {mac} の PXE を無効化しました")
        else:
            self.send_response(404)
            self.end_headers()

    def _disable_pxe(self, mac):
        existing = ""
        if os.path.exists(DNSMASQ_INSTALLED_CONF):
            with open(DNSMASQ_INSTALLED_CONF) as f:
                existing = f.read()
        if mac not in existing:
            with open(DNSMASQ_INSTALLED_CONF, "a") as f:
                f.write(f"# PXE disabled after installation\n")
                f.write(f"dhcp-host={mac},ignore\n")
            subprocess.run(["systemctl", "restart", "dnsmasq"], check=True)

    def log_message(self, format, *args):
        print(f"{self.address_string()} {format % args}")


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", 9000), WebhookHandler)
    print("Webhook server listening on :9000")
    server.serve_forever()
