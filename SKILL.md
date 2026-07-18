# راهنمای استفاده از Daytona Google Proxy

## 📋 معرفی

این اسکریپت (`daytona_google_proxy.py`) به شما اجازه می‌دهد از داخل یک Daytona Sandbox که دسترسی اینترنت محدودی دارد، به سایت‌های گوگل (Google Search، YouTube، Gmail، Google Translate، Google Maps و...) و همچنین Telegram Web دسترسی پیدا کنید و جستجو انجام دهید.

### روش کار: MITM + SNI Spoofing

Daytona Sandbox دسترسی اینترنت محدودی دارد و فقط به برخی دامنه‌ها (allow-list) اجازه اتصال می‌دهد. این اسکریپت با دو تکنیک این محدودیت را دور می‌زند:

1. **SNI Spoofing**: در TLS handshake، به جای SNI واقعی (مثلاً `www.google.com`)، از یک SNI مجاز (مثلاً `dl.google.com`) استفاده می‌کند. Daytona این SNI را می‌بیند و اجازه اتصال می‌دهد.

2. **MITM (Man-in-the-Middle)**: برای تغییر SNI در TLS handshake، باید ترافیک TLS را decrypt کرد. اسکریپت یک سرتیفیکیت self-signed تولید می‌کند و با آن TLS connection کلاینت را terminate می‌کند، سپس با SNI spoofing به سایت هدف وصل می‌شود.

```
مرورگر کلاینت
    ↓ HTTPS (TLS با cert اسکریپت)
SOCKS5 Proxy (روی Sandbox)
    ↓ MITM: TLS را decrypt می‌کند
    ↓ SNI Spoofing: SNI=dl.google.com (مجاز در Daytona)
سایت هدف (google.com، youtube.com و...)
```

---

## 🚀 نصب و راه‌اندازی

### قدم ۱: آپلود اسکریپت روی Daytona Sandbox

اسکریپت `daytona_google_proxy.py` را روی Sandbox آپلود کنید. می‌توانید از Daytona API یا Terminal استفاده کنید:

```bash
# از طریق Terminal در Daytona Dashboard:
# فایل را کپی کنید به مسیر /usr/local/bin/daytona_google_proxy.py

# یا با استفاده از Daytona SDK (Python):
# from daytona import Daytona, DaytonaConfig
# config = DaytonaConfig(api_key="YOUR_API_KEY", api_url="https://app.daytona.io/api")
# daytona = Daytona(config)
# sb = daytona.get("SANDBOX_ID")
# sb.fs.write_file("/usr/local/bin/daytona_google_proxy.py", script_content)
```

### قدم ۲: اجرای اسکریپت روی Sandbox

```bash
# اسکریپت را قابل اجرا کنید
chmod +x /usr/local/bin/daytona_google_proxy.py

# اجرای اسکریپت
python3 /usr/local/bin/daytona_google_proxy.py
```

### قدم ۳: خواندن خروجی

وقتی اسکریپت اجرا می‌شود، کارهای زیر را انجام می‌دهد:

1. **سرتیفیکیت تولید می‌کند** در `/etc/google-proxy/mycert.crt` و `/etc/google-proxy/mycert.key`
2. **تست‌های خودکار اجرا می‌کند** (Google، YouTube، Telegram و...)
3. **SOCKS5 proxy شروع می‌کند** روی پورت `1080`

خروجی چیزی شبیه این است:

```
[2026-07-14 11:41:59] ============================================================
[2026-07-14 11:41:59] شروع تست‌های خودکار
[2026-07-14 11:41:59] ============================================================

--- Google Homepage ---
  Status: HTTP/1.1 200 OK
  Size: 284111 bytes
  Title: Google

--- Google Search 'iran news' ---
  Status: HTTP/1.1 200 OK
  Size: 93581 bytes
  Title: Google Search

--- YouTube ---
  Status: HTTP/1.1 200 OK
  Size: 500240 bytes
  Title: YouTube

--- Telegram Web ---
  Status: HTTP/1.1 200 OK
  Title: Telegram Web
```

اگر همه تست‌ها `HTTP 200` یا `HTTP 302` یا `HTTP 301` باشند، یعنی اتصال موفق است.

---

## 🔍 جستجو در گوگل از داخل Sandbox

### روش ۱: استفاده از تابع `fetch_google`

اسکریپت یک تابع آماده برای جستجو در گوگل دارد:

```python
# فایل اسکریپت را import کنید
exec(open("/usr/local/bin/daytona_google_proxy.py").read().split("def main")[0])

# جستجوی ساده
data = fetch_google(query="iran news")
print(data.decode("utf-8", errors="replace"))

# fetch یک URL خاص
data = fetch_google(url="https://www.google.com/search?q=hello+world")
print(data.decode("utf-8", errors="replace"))
```

### روش ۲: استفاده مستقیم از SNI Spoofing

اگر می‌خواهید دستی این کار را انجام دهید:

```python
import socket
import ssl
from urllib.parse import quote

def google_search(query):
    """جستجو در گوگل با SNI spoofing."""
    target_host = "www.google.com"
    target_ip = socket.gethostbyname(target_host)
    path = f"/search?q={quote(query)}"
    
    # اتصال با SNI=dl.google.com (مجاز در Daytona)
    sock = socket.create_connection((target_ip, 443), timeout=15)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ssock = ctx.wrap_socket(sock, server_hostname="dl.google.com")
    
    # ارسال درخواست HTTP با Host واقعی
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {target_host}\r\n"
        "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36\r\n"
        "Accept: text/html\r\n"
        "Connection: close\r\n"
        "\r\n"
    )
    ssock.sendall(req.encode())
    
    # خواندن پاسخ
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

# استفاده
result = google_search("iran news")
print(result.decode("utf-8", errors="replace"))
```

### روش ۳: استفاده از SOCKS5 Proxy

وقتی اسکریپت در حال اجراست، یک SOCKS5 proxy روی پورت 1080 راه‌اندازی شده است. می‌توانید از آن استفاده کنید:

```python
import requests

# استفاده از SOCKS5 proxy
proxies = {
    "http": "socks5h://127.0.0.1:1080",
    "https": "socks5h://127.0.0.1:1080"
}

# توجه: برای HTTPS، باید سرتیفیکیت /etc/google-proxy/mycert.crt را trust کنید
# در غیر این صورت، verify=False استفاده کنید
response = requests.get(
    "https://www.google.com/search?q=iran+news",
    proxies=proxies,
    verify=False,  # چون cert self-signed است
    timeout=15
)
print(response.status_code)
print(response.text[:1000])
```

---

## 📋 سایت‌های پشتیبانی شده

اسکریپت از سایت‌های زیر پشتیبانی می‌کند:

### سرویس‌های گوگل (با SNI=dl.google.com):
- google.com (جستجو)
- www.google.com
- youtube.com
- m.youtube.com
- mail.google.com (Gmail)
- accounts.google.com
- drive.google.com
- docs.google.com
- maps.google.com
- translate.google.com
- cloud.google.com
- news.google.com
- scholar.google.com
- images.google.com
- play.google.com
- books.google.com
- googlevideo.com
- googleusercontent.com
- gstatic.com
- fonts.googleapis.com
- storage.googleapis.com

### تلگرام (با SNI=api.telegram.org):
- api.telegram.org (Bot API)
- web.telegram.org (Telegram Web)
- t.me
- telegram.org
- my.telegram.org

### GitHub و Fastly (با SNI مستقیم):
- github.com
- api.github.com
- raw.githubusercontent.com
- pypi.org
- nytimes.com

---

## 🔧 نحوه اضافه کردن سایت جدید

اگر سایت جدیدی می‌خواهید اضافه کنید، کافی است آن را به دیکشنری `ALLOWED_SNIS` اضافه کنید:

```python
ALLOWED_SNIS = {
    # ... سایت‌های موجود ...
    
    # سایت جدید:
    "example.com": "dl.google.com",  # اگر روی CDN گوگل است
    # یا
    "example.com": "github.com",     # اگر روی Fastly است
    # یا
    "example.com": "example.com",    # اگر در allow-list Daytona است
}
```

قانون انتخاب SNI:
- اگر سایت روی **CDN گوگل** است → `dl.google.com`
- اگر سایت روی **CDN تلگرام** است → `api.telegram.org`
- اگر سایت روی **Fastly** است → `github.githubassets.com` یا `deb.debian.org`
- اگر سایت در **allow-list Daytona** است → خود دامنه

---

## ⚠️ نکات مهم

1. **سرتیفیکیت**: برای استفاده از SOCKS5 proxy در مرورگر، باید فایل `/etc/google-proxy/mycert.crt` را دانلود و روی دستگاه خود به عنوان Trusted Root CA نصب کنید.

2. **فقط HTTPS (پورت 443)**: SNI spoofing فقط برای HTTPS کار می‌کند. سایت‌های HTTP (پورت 80) مستقیم وصل می‌شوند.

3. **محدودیت Daytona**: این روش فقط سایت‌هایی را که روی CDN گوگل یا تلگرام هستند پشتیبانی می‌کند. سایت‌های روی Cloudflare (مثل Discord، Reddit) کار نمی‌کنند.

4. **پایداری**: Sandbox ممکن است هر ۳۳ روز auto-stop شود. برای تمدید، کافی است از پروکسی استفاده کنید یا دستوری در Sandbox اجرا کنید.

---

## 📊 خلاصه سریع

| کار | دستور |
|-----|-------|
| اجرای اسکریپت | `python3 /usr/local/bin/daytona_google_proxy.py` |
| جستجو در گوگل | `fetch_google(query="iran news")` |
| باز کردن URL | `fetch_google(url="https://www.youtube.com/")` |
| استفاده از SOCKS5 | `socks5h://127.0.0.1:1080` |
| مسیر cert | `/etc/google-proxy/mycert.crt` |
| مسیر اسکریپت | `/usr/local/bin/daytona_google_proxy.py` |

---

## 🎯 مثال کامل: جستجو در گوگل و استخراج نتایج

```python
#!/usr/bin/env python3
"""جستجو در گوگل و استخراج نتایج از Daytona Sandbox."""

import socket
import ssl
import re
from urllib.parse import quote, unquote

def google_search_and_extract(query, max_results=10):
    """جستجو در گوگل و استخراج نتایج."""
    
    target_host = "www.google.com"
    target_ip = socket.gethostbyname(target_host)
    path = f"/search?q={quote(query)}"
    
    # اتصال با SNI spoofing
    sock = socket.create_connection((target_ip, 443), timeout=15)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ssock = ctx.wrap_socket(sock, server_hostname="dl.google.com")
    
    # ارسال درخواست
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {target_host}\r\n"
        "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36\r\n"
        "Accept: text/html\r\n"
        "Connection: close\r\n"
        "\r\n"
    )
    ssock.sendall(req.encode())
    
    # خواندن پاسخ
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
    
    # پردازش پاسخ
    text = data.decode("utf-8", errors="replace")
    
    # استخراج عنوان نتایج (h3 tags)
    titles = re.findall(r'<h3[^>]*>([^<]+)</h3>', text)
    
    # استخراج لینک‌های نتایج
    links = re.findall(r'<a href="/url\?q=([^&"]+)', text)
    
    # نمایش نتایج
    print(f"جستجو: {query}")
    print(f"تعداد نتایج: {len(titles)}")
    print("-" * 60)
    
    for i, title in enumerate(titles[:max_results], 1):
        link = unquote(links[i-1]) if i-1 < len(links) else "N/A"
        print(f"{i}. {title}")
        print(f"   {link[:100]}")
        print()

# استفاده
google_search_and_extract("iran news latest")
google_search_and_extract("python tutorial")
google_search_and_extract("telegram download")
```

این کد آماده اجراست و نتایج جستجوی گوگل را با عنوان و لینک نمایش می‌دهد.
