#!/usr/bin/env python3
"""Occupy 127.0.0.1:<port> with a non-maclang listener for the contract scripts.

usage: port-holder.py <port> <error-file>

Binds with SO_REUSEADDR, retrying for up to 30 s (a previous server's connections can leave the
port in TIME_WAIT), then accepts connections until killed. Each connection gets a minimal
non-maclang HTTP 200 answer ({"status":"ok"} has no version), so maclang's health probe classifies
the listener as "foreign". Errors go to <error-file>, which the calling script prints on failure.
"""
import socket
import sys
import time

port, errfile = int(sys.argv[1]), sys.argv[2]
BODY = b'{"status":"ok"}'
RESPONSE = (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
            b"Connection: close\r\n\r\n" % len(BODY)) + BODY


def log(message):
    with open(errfile, "a") as handle:
        handle.write(message + "\n")


server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
last = None
for _ in range(150):  # 30 s in 0.2 s steps
    try:
        server.bind(("127.0.0.1", port))
        last = None
        break
    except OSError as error:
        last = error
        time.sleep(0.2)
if last is not None:
    log(f"port-holder: could not bind 127.0.0.1:{port} within 30 s: {last}")
    sys.exit(1)
server.listen(16)

while True:
    try:
        conn, _ = server.accept()
    except OSError as error:
        log(f"port-holder: accept failed: {error}")
        continue
    try:
        conn.settimeout(1)
        try:
            conn.recv(4096)
        except OSError:
            pass
        conn.sendall(RESPONSE)
    except OSError as error:
        log(f"port-holder: connection error: {error}")
    finally:
        conn.close()
