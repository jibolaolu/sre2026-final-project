#!/usr/bin/env python3
"""
HTTP CONNECT proxy for WSL2 → minikube internet connectivity.

Listens on 0.0.0.0:3128.  minikube pods set HTTPS_PROXY=http://192.168.58.1:3128
and route all HTTPS traffic here; this script resolves and relays the TCP tunnel.

Start:  python3 k8s/scripts/k8s-proxy.py &
Stop:   kill $(pgrep -f k8s-proxy.py)
"""
import select
import socket
import sys
import threading


def _relay(a: socket.socket, b: socket.socket) -> None:
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 60)
            if not r:
                break
            for src in r:
                dst = b if src is a else a
                data = src.recv(8192)
                if not data:
                    return
                dst.sendall(data)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try:
                s.close()
            except Exception:
                pass


def _handle(client: socket.socket) -> None:
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = client.recv(4096)
            if not chunk:
                return
            buf += chunk

        first_line = buf.split(b"\r\n")[0].decode()
        parts = first_line.split()
        if len(parts) < 3 or parts[0].upper() != "CONNECT":
            return

        host, _, port_str = parts[1].rpartition(":")
        port = int(port_str) if port_str.isdigit() else 443

        upstream = socket.create_connection((host, port), timeout=30)
        client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")

        t = threading.Thread(target=_relay, args=(client, upstream), daemon=True)
        t.start()
        t.join()
    except Exception as exc:
        print(f"[proxy] {exc}", file=sys.stderr)
        try:
            client.close()
        except Exception:
            pass


def main(port: int = 3128) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", port))
        srv.listen(128)
        print(f"[proxy] listening on 0.0.0.0:{port}", flush=True)
        while True:
            try:
                client, addr = srv.accept()
                threading.Thread(target=_handle, args=(client,), daemon=True).start()
            except KeyboardInterrupt:
                print("[proxy] shutting down")
                break


if __name__ == "__main__":
    main()
