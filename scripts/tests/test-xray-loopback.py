#!/usr/bin/env python3
"""Test actual TCP/UDP through generated outbounds with trusted local TLS."""
import copy
import http.server
import json
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time


def port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def recv_exact(s, count):
    result = b""
    while len(result) < count:
        data = s.recv(count - len(result))
        if not data:
            raise RuntimeError("SOCKS connection closed")
        result += data
    return result


def udp_probe(socks_port, echo_port):
    with socket.create_connection(("127.0.0.1", socks_port), timeout=5) as control:
        control.sendall(b"\x05\x01\x00")
        assert recv_exact(control, 2) == b"\x05\x00"
        control.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        header = recv_exact(control, 4)
        assert header[:2] == b"\x05\x00", header
        assert header[3] == 1, header
        address = socket.inet_ntoa(recv_exact(control, 4))
        bound_port = struct.unpack("!H", recv_exact(control, 2))[0]
        if address == "0.0.0.0":
            address = "127.0.0.1"
        message = b"native-hysteria2-udp"
        packet = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", echo_port) + message
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.settimeout(10)
            udp.sendto(packet, (address, bound_port))
            reply, _ = udp.recvfrom(4096)
            assert reply.endswith(message), reply


class HTTPHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = b"native-xray-tcp-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, s = self.request
        s.sendto(data, self.client_address)


def start(xray, config, directory, name):
    path = directory / (name + ".json")
    path.write_text(json.dumps(config))
    subprocess.run([xray, "run", "-test", "-config", str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    output = (directory / (name + ".log")).open("wb")
    return subprocess.Popen([xray, "run", "-config", str(path)], stdout=output, stderr=subprocess.STDOUT), output


def run_case(xray, original, directory, name, http_port, echo_port):
    outbound = copy.deepcopy(original["outbounds"][0])
    protocol = outbound["protocol"]
    server_port = port(socket.SOCK_DGRAM if protocol == "hysteria" else socket.SOCK_STREAM)
    stream = outbound["streamSettings"]
    stream["tlsSettings"]["serverName"] = "localhost"
    stream["tlsSettings"]["certificates"] = [{"certificateFile": str(directory / "cert.pem"), "usage": "verify"}]
    server_stream = copy.deepcopy(stream)
    server_stream["tlsSettings"] = {"alpn": ["h3"] if protocol == "hysteria" else ["http/1.1"],
                                   "certificates": [{"certificateFile": str(directory / "cert.pem"), "keyFile": str(directory / "key.pem")}]}
    if protocol == "hysteria":
        outbound["settings"].update(address="127.0.0.1", port=server_port)
        server_settings = {"version": 2, "clients": [{"auth": stream["hysteriaSettings"]["auth"]}]}
        # Port-hopping syntax is checked against the real core in Go tests.
        # One-port loopback traffic tests TCP/UDP and Salamander interoperability.
        for settings in (stream, server_stream):
            if settings.get("finalmask", {}).get("quicParams"):
                settings["finalmask"]["quicParams"].pop("udpHop", None)
    elif protocol == "trojan":
        remote = outbound["settings"]["servers"][0]
        remote.update(address="127.0.0.1", port=server_port)
        server_settings = {"clients": [{"password": remote["password"]}]}
    elif protocol == "vless":
        remote = outbound["settings"]["vnext"][0]
        remote.update(address="127.0.0.1", port=server_port)
        server_settings = {"decryption": "none", "clients": [{"id": remote["users"][0]["id"]}]}
    else:
        raise AssertionError(protocol)
    server = {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "127.0.0.1", "port": server_port, "protocol": protocol,
              "settings": server_settings, "streamSettings": server_stream}], "outbounds": [{"protocol": "freedom"}]}
    socks_port = port()
    client = {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "127.0.0.1", "port": socks_port, "protocol": "socks",
              "settings": {"auth": "noauth", "udp": True}}], "outbounds": [outbound]}
    processes, files = [], []
    try:
        for config, suffix in ((server, "server"), (client, "client")):
            proc, output = start(xray, config, directory, name + "-" + suffix)
            processes.append(proc); files.append(output)
        deadline = time.monotonic() + 10
        while True:
            assert all(p.poll() is None for p in processes), "Xray process exited"
            try:
                with socket.create_connection(("127.0.0.1", socks_port), timeout=0.2):
                    break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError("Xray did not start")
                time.sleep(0.05)
        result = subprocess.run(["curl", "--fail", "--silent", "--show-error", "--max-time", "15", "--noproxy", "",
                                 "--socks5-hostname", f"127.0.0.1:{socks_port}", f"http://127.0.0.1:{http_port}/probe"], check=True, capture_output=True)
        assert result.stdout == b"native-xray-tcp-ok", result.stdout
        udp_probe(socks_port, echo_port)
        print(name + ": TCP and UDP passed (trusted TLS)", flush=True)
    except Exception:
        for p in directory.glob(name + "-*.log"):
            print(p.name + "\n" + p.read_text(errors="replace"), file=sys.stderr)
        raise
    finally:
        for p in processes:
            p.terminate()
        for p in processes:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill(); p.wait()
        for f in files:
            f.close()


def main():
    xray, fixture_dir = sys.argv[1], Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(directory / "key.pem"),
                        "-out", str(directory / "cert.pem"), "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
                        "-addext", "basicConstraints=critical,CA:TRUE"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        web = http.server.HTTPServer(("127.0.0.1", 0), HTTPHandler)
        udp = socketserver.UDPServer(("127.0.0.1", 0), UDPHandler)
        for server in (web, udp):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for number, name in ((0, "trojan-tls"), (1, "vless-ws-tls"), (3, "hysteria2-tls"), (4, "hysteria2-salamander")):
                run_case(xray, json.loads((fixture_dir / f"outbound-{number}.json").read_text()), directory, name,
                         web.server_port, udp.server_address[1])
            # Validate the date-dependent removal using the exact release binary.
            config = json.loads((fixture_dir / "outbound-0.json").read_text())
            config["outbounds"][0]["streamSettings"]["tlsSettings"]["allowInsecure"] = True
            file = directory / "insecure.json"; file.write_text(json.dumps(config))
            result = subprocess.run([xray, "run", "-test", "-config", str(file)], capture_output=True)
            if time.time() > 1780272000:  # 2026-06-01 UTC
                assert result.returncode != 0 and b"allowInsecure" in result.stdout + result.stderr
                print("allowInsecure removal: confirmed", flush=True)
        finally:
            web.shutdown(); web.server_close()
            udp.shutdown(); udp.server_close()


if __name__ == "__main__":
    main()
