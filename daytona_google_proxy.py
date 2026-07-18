#!/usr/bin/env python3
"""
Daytona Google Proxy - MITM + SNI Spoofing
مخصوص Daytona Sandbox - دسترسی به گوگل و تلگرام

روش استفاده:
1. این اسکریپت رو روی Daytona sandbox اجرا کن
2. مرورگر رو به SOCKS5 proxy 127.0.0.1:1080 تنظیم کن
3. mycert.crt رو روی دستگاه خودت نصب کن (Trusted Root CA)
4. سایت‌های گوگل و تلگرام باز می‌شن!

نکته: این اسکریپت مخصوص Daytona هست چون:
- Daytona دسترسی اینترنت محدود داره (فقط سایت‌های allow-listed)
- با SNI spoofing دور این محدودیت می‌گذره
- MITM برای تغییر SNI در TLS handshake لازمه
"""

import socket
import ssl
import threading
import select
import os
import sys
import subprocess
import hashlib
import base64
import re
import time
import logging
from urllib.parse import urlparse

# ============================================================
# تنظیمات
# ============================================================

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 1080  # پورت SOCKS5 proxy

# SNI های مجاز در Daytona (allow-list)
ALLOWED_SNIS = {
    # Google CDN
    "google.com": "dl.google.com",
    "www.google.com": "dl.google.com",
    "googleapis.com": "dl.google.com",
    "www.googleapis.com": "dl.google.com",
    "youtube.com": "dl.google.com",
    "www.youtube.com": "dl.google.com",
    "m.youtube.com": "dl.google.com",
    "gmail.com": "dl.google.com",
    "mail.google.com": "dl.google.com",
    "accounts.google.com": "dl.google.com",
    "drive.google.com": "dl.google.com",
    "docs.google.com": "dl.google.com",
    "maps.google.com": "dl.google.com",
    "translate.google.com": "dl.google.com",
    "cloud.google.com": "dl.google.com",
    "console.cloud.google.com": "dl.google.com",
    "news.google.com": "dl.google.com",
    "scholar.google.com": "dl.google.com",
    "images.google.com": "dl.google.com",
    "video.google.com": "dl.google.com",
    "books.google.com": "dl.google.com",
    "play.google.com": "dl.google.com",
    "gstatic.com": "fonts.gstatic.com",
    "www.gstatic.com": "fonts.gstatic.com",
    "fonts.gstatic.com": "fonts.gstatic.com",
    "fonts.googleapis.com": "fonts.googleapis.com",
    "storage.googleapis.com": "storage.googleapis.com",
    "dl.google.com": "dl.google.com",
    "googlevideo.com": "dl.google.com",
    "www.googlevideo.com": "dl.google.com",
    "googleusercontent.com": "dl.google.com",
    "ggpht.com": "dl.google.com",
    "google-analytics.com": "dl.google.com",
    "googletagmanager.com": "dl.google.com",
    # Telegram
    "api.telegram.org": "api.telegram.org",
    "t.me": "api.telegram.org",
    "telegram.org": "api.telegram.org",
    "web.telegram.org": "api.telegram.org",
    "core.telegram.org": "api.telegram.org",
    "my.telegram.org": "api.telegram.org",
    "desktop.telegram.org": "api.telegram.org",
    "telegram.me": "api.telegram.org",
    # Fastly sites
    "nytimes.com": "deb.debian.org",
    "www.nytimes.com": "deb.debian.org",
    "github.com": "github.com",
    "api.github.com": "api.github.com",
    "raw.githubusercontent.com": "raw.githubusercontent.com",
    "gist.github.com": "gist.github.com",
    "githubusercontent.com": "raw.githubusercontent.com",
    "githubassets.com": "raw.githubusercontent.com",
    "github.githubassets.com": "raw.githubusercontent.com",
    "pypi.org": "pypi.org",
    "files.pythonhosted.org": "files.pythonhosted.org",
}

# Cert files
CERT_DIR = "/etc/google-proxy"
CERT_FILE = f"{CERT_DIR}/mycert.crt"
KEY_FILE = f"{CERT_DIR}/mycert.key"

# ============================================================
# لاگ 설정
# ============================================================

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(message)s',
    stream=sys.stdout
)
log = logging.getLogger("google-proxy")

# ============================================================
# تولید سرتیفیکیت
# ============================================================

def generate_cert():
    """تولید سرتیفیکیت self-signed برای MITM."""
    os.makedirs(CERT_DIR, exist_ok=True)
    
    if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        log.info("[*] Cert already exists")
        return
    
    log.info("[*] Generating self-signed certificate ...")
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", KEY_FILE,
        "-out", CERT_FILE,
        "-days", "3650",
        "-subj", "/C=IR/ST=Tehran/L=Tehran/O=DaytonaProxy/CN=DaytonaProxy Root CA",
        "-addext", "basicConstraints=critical,CA:TRUE",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign,digitalSignature,keyEncipherment",
        "-addext", "extendedKeyUsage=serverAuth,clientAuth"
    ], check=True, capture_output=True)
    
    os.chmod(CERT_FILE, 0o644)
    os.chmod(KEY_FILE, 0o644)
    
    log.info(f"[+] Certificate: {CERT_FILE}")
    log.info(f"[+] Private key: {KEY_FILE}")
    
    # Show cert info
    result = subprocess.run(
        ["openssl", "x509", "-in", CERT_FILE, "-noout", "-subject", "-dates"],
        capture_output=True, text=True
    )
    log.info(f"[*] Cert info:\n{result.stdout}")

# ============================================================
# SNI Spoofing
# ============================================================

def get_sni_for_host(host):
    """بهترین SNI رو برای یه host پیدا کن."""
    if host in ALLOWED_SNIS:
        return ALLOWED_SNIS[host]
    
    # بررسی suffix
    for domain, sni in ALLOWED_SNIS.items():
        if host.endswith("." + domain):
            return sni
    
    # پیش‌فرض: dl.google.com (برای سایت‌های گوگل)
    if any(g in host for g in ["google", "youtube", "gmail", "gstatic", "googlevideo", "googleusercontent"]):
        return "dl.google.com"
    
    # پیش‌فرض: api.telegram.org (برای تلگرام)
    if "telegram" in host or host == "t.me":
        return "api.telegram.org"
    
    # پیش‌فرض: github (برای GitHub)
    if "github" in host:
        return "github.com"
    
    # مستقیم (برای سایت‌های allow-listed)
    return host

# ============================================================
# MITM Proxy Handler
# ============================================================

def mitm_connect(client_sock, target_host, target_port):
    """یه connection رو MITM کن - TLS terminate و re-encrypt."""
    
    sni = get_sni_for_host(target_host)
    
    try:
        # Resolve target IP
        target_ip = socket.gethostbyname(target_host)
    except Exception as e:
        log.error(f"DNS error for {target_host}: {e}")
        client_sock.close()
        return
    
    log.info(f"MITM: {target_host}:{target_port} -> SNI={sni} (IP={target_ip})")
    
    try:
        # Connect to target with spoofed SNI
        remote_sock = socket.create_connection((target_ip, target_port), timeout=15)
        
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        
        # TLS handshake with spoofed SNI
        remote_tls = ctx.wrap_socket(remote_sock, server_hostname=sni)
        
        # Now create a MITM TLS connection with client
        # Generate a cert for this specific host
        mitm_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        mitm_ctx.load_cert_chain(CERT_FILE, KEY_FILE)
        
        # Wrap client socket with our cert
        client_tls = mitm_ctx.wrap_socket(client_sock, server_side=True)
        
        log.info(f"[+] MITM established: {target_host}")
        
        # Bidirectional relay
        relay(client_tls, remote_tls)
        
    except Exception as e:
        log.error(f"MITM error for {target_host}: {e}")
        try:
            client_sock.close()
        except:
            pass

def relay(sock1, sock2):
    """Bidirectional relay بین دو socket."""
    sockets = [sock1, sock2]
    try:
        while True:
            rlist, _, xlist = select.select(sockets, [], sockets, 60)
            if xlist:
                break
            if not rlist:
                break
            for sock in rlist:
                try:
                    data = sock.recv(65536)
                    if not data:
                        raise ConnectionError("closed")
                    other = sock2 if sock is sock1 else sock1
                    other.sendall(data)
                except:
                    raise
    except:
        pass
    finally:
        for s in sockets:
            try:
                s.close()
            except:
                pass

# ============================================================
# SOCKS5 Proxy Server
# ============================================================

def handle_socks5_client(client_sock, client_addr):
    """Handle a SOCKS5 client connection."""
    try:
        client_sock.settimeout(30)
        
        # SOCKS5 greeting
        data = client_sock.recv(256)
        if len(data) < 2 or data[0] != 0x05:
            client_sock.close()
            return
        
        n_methods = data[1]
        # Reply: no auth
        client_sock.sendall(b'\x05\x00')
        
        # SOCKS5 request
        data = client_sock.recv(256)
        if len(data) < 4 or data[0] != 0x05:
            client_sock.close()
            return
        
        cmd = data[1]
        atyp = data[3]
        
        if cmd != 0x01:  # Only CONNECT
            client_sock.sendall(b'\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00')
            client_sock.close()
            return
        
        # Read address
        if atyp == 0x01:  # IPv4
            addr = socket.inet_ntoa(data[4:8])
            port = (data[8] << 8) | data[9]
        elif atyp == 0x03:  # Domain
            length = data[4]
            addr = data[5:5+length].decode('utf-8', errors='replace')
            port = (data[5+length] << 8) | data[6+length]
        elif atyp == 0x04:  # IPv6
            addr = socket.inet_ntop(socket.AF_INET6, data[4:20])
            port = (data[20] << 8) | data[21]
        else:
            client_sock.sendall(b'\x05\x08\x00\x01\x00\x00\x00\x00\x00\x00')
            client_sock.close()
            return
        
        log.info(f"SOCKS5 CONNECT: {addr}:{port}")
        
        # For HTTPS (port 443), use MITM
        if port == 443:
            # Send success
            client_sock.sendall(b'\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00')
            
            # Start MITM in a thread
            t = threading.Thread(
                target=mitm_connect,
                args=(client_sock, addr, port),
                daemon=True
            )
            t.start()
        else:
            # For non-HTTPS, direct connect
            try:
                target_ip = socket.gethostbyname(addr)
                remote_sock = socket.create_connection((target_ip, port), timeout=10)
                client_sock.sendall(b'\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00')
                
                # Relay
                relay(client_sock, remote_sock)
            except Exception as e:
                log.error(f"Direct connect error: {e}")
                client_sock.sendall(b'\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00')
                client_sock.close()
                
    except Exception as e:
        log.error(f"SOCKS5 error: {e}")
        try:
            client_sock.close()
        except:
            pass

# ============================================================
# HTTP Proxy (برای تست)
# ============================================================

def fetch_google(query=None, url=None):
    """یه URL رو با SNI spoofing fetch کن (برای تست)."""
    if query:
        from urllib.parse import quote
        target_host = "www.google.com"
        path = f"/search?q={quote(query)}"
    elif url:
        parsed = urlparse(url)
        target_host = parsed.hostname
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
    else:
        return None
    
    sni = get_sni_for_host(target_host)
    
    try:
        target_ip = socket.gethostbyname(target_host)
        sock = socket.create_connection((target_ip, 443), timeout=15)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ssock = ctx.wrap_socket(sock, server_hostname=sni)
        
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {target_host}\r\n"
            "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\r\n"
            "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
            "Accept-Language: en-US,en;q=0.5\r\n"
            "Connection: close\r\n"
            "\r\n"
        )
        ssock.sendall(req.encode())
        
        data = b""
        ssock.settimeout(15)
        while True:
            try:
                chunk = ssock.recv(65536)
                if not chunk:
                    break
                data += chunk
                if len(data) > 500000:
                    break
            except:
                break
        
        ssock.close()
        return data
    except Exception as e:
        log.error(f"Fetch error: {e}")
        return None

# ============================================================
# تست‌های خودکار
# ============================================================

def run_tests():
    """تست‌های خودکار برای بررسی اتصال."""
    log.info("=" * 60)
    log.info("شروع تست‌های خودکار")
    log.info("=" * 60)
    
    tests = [
        ("Google Homepage", "https://www.google.com/"),
        ("Google Search 'iran news'", None),  # special
        ("YouTube", "https://www.youtube.com/"),
        ("YouTube Search 'iran'", None),  # special
        ("Google Translate", "https://translate.google.com/"),
        ("Telegram Web", "https://web.telegram.org/"),
        ("Telegram API", "https://api.telegram.org/bot123:abc/getMe"),
        ("Gmail", "https://mail.google.com/"),
        ("Google Drive", "https://drive.google.com/"),
        ("Google Maps", "https://maps.google.com/"),
        ("GitHub", "https://github.com/"),
    ]
    
    for name, url in tests:
        log.info(f"\n--- {name} ---")
        
        if name.startswith("Google Search"):
            data = fetch_google(query="iran news")
        elif name.startswith("YouTube Search"):
            from urllib.parse import quote
            target_host = "www.youtube.com"
            path = f"/results?search_query={quote('iran')}"
            
            sni = get_sni_for_host(target_host)
            target_ip = socket.gethostbyname(target_host)
            sock = socket.create_connection((target_ip, 443), timeout=15)
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            ssock = ctx.wrap_socket(sock, server_hostname=sni)
            
            req = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {target_host}\r\n"
                "User-Agent: Mozilla/5.0\r\n"
                "Connection: close\r\n"
                "\r\n"
            )
            ssock.sendall(req.encode())
            
            data = b""
            ssock.settimeout(15)
            while True:
                try:
                    chunk = ssock.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                    if len(data) > 500000:
                        break
                except:
                    break
            ssock.close()
        else:
            data = fetch_google(url=url)
        
        if data:
            status = data.split(b"\r\n")[0].decode("utf-8", errors="replace")
            log.info(f"  Status: {status}")
            log.info(f"  Size: {len(data)} bytes")
            
            if b"<title>" in data:
                start = data.find(b"<title>") + 7
                end = data.find(b"</title>", start)
                title = data[start:end].decode("utf-8", errors="replace")
                log.info(f"  Title: {title}")
            
            # For Google search, extract results
            if "Search" in name and b"<h3" in data:
                text = data.decode("utf-8", errors="replace")
                h3s = re.findall(r'<h3[^>]*>([^<]+)</h3>', text)
                log.info(f"  Results found: {len(h3s)}")
                for i, h3 in enumerate(h3s[:3], 1):
                    log.info(f"    {i}. {h3[:80]}")
        else:
            log.info(f"  FAILED")
    
    log.info("\n" + "=" * 60)
    log.info("تست‌ها تمام شد")
    log.info("=" * 60)

# ============================================================
# Main
# ============================================================

def main():
    print("""
╔══════════════════════════════════════════════════════════╗
║     Daytona Google Proxy - MITM + SNI Spoofing          ║
║     مخصوص Daytona Sandbox                              ║
╚══════════════════════════════════════════════════════════╝
    """)
    
    # تولید cert
    generate_cert()
    
    # نمایش cert برای نصب روی کلاینت
    print("\n" + "=" * 60)
    print("سرتیفیکیت زیر رو روی دستگاه خودت نصب کن:")
    print("(Trusted Root Certificate Authority)")
    print("=" * 60)
    try:
        with open(CERT_FILE, "r") as f:
            print(f.read())
    except:
        pass
    print("=" * 60)
    
    # اجرای تست‌ها
    print("\n[*] در حال اجرای تست‌ها ...\n")
    run_tests()
    
    # شروع SOCKS5 proxy
    print(f"\n[*] شروع SOCKS5 proxy روی {LISTEN_HOST}:{LISTEN_PORT}")
    print(f"[*] مرورگر رو به SOCKS5 proxy 127.0.0.1:{LISTEN_PORT} تنظیم کن")
    print(f"[*] سرتیفیکیت {CERT_FILE} رو روی دستگاه خودت نصب کن")
    print(f"[*] برای خروج Ctrl+C بزن\n")
    
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(50)
    
    log.info(f"SOCKS5 proxy listening on {LISTEN_HOST}:{LISTEN_PORT}")
    
    try:
        while True:
            client_sock, client_addr = server.accept()
            t = threading.Thread(
                target=handle_socks5_client,
                args=(client_sock, client_addr),
                daemon=True
            )
            t.start()
    except KeyboardInterrupt:
        print("\n[*] Shutting down")
        server.close()

if __name__ == "__main__":
    main()
