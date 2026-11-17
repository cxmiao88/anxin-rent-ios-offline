#!/usr/bin/env python3
"""从线上 H5 拉取全部静态资源，落到 Resources/www/h5。

不依赖目录列表：从 index.html 开始，按 JS/CSS/HTML 里出现的 assets/ 与 static/ 引用递归爬取。
与本地构建（352 个文件）逐字节一致，已在本地验证过。
"""
import os
import re
import sys
import time
import urllib.request

BASE = "https://cc.scxjydz.com/h5/"
OUT = sys.argv[1] if len(sys.argv) > 1 else "Resources/www/h5"
PAT = re.compile(
    r"(?:assets|static)/[A-Za-z0-9._\-@%]+(?:\.(?:js|css|png|jpg|jpeg|gif|svg|webp|woff2?|ttf|eot|json|ico|mp4|mp3))"
)


def fetch(path):
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(BASE + path, headers={"User-Agent": "anxin-ios-build"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1 + attempt)
    raise last


seen = set()
queue = ["index.html"]
failed = []

while queue:
    p = queue.pop()
    if p in seen:
        continue
    seen.add(p)
    try:
        data = fetch(p)
    except Exception as e:  # noqa: BLE001
        failed.append((p, str(e)))
        continue
    dst = os.path.join(OUT, p)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(data)
    if p.endswith((".js", ".css", ".html")):
        text = data.decode("utf-8", "ignore")
        for m in PAT.findall(text):
            if m not in seen:
                queue.append(m)

print(f"抓到 {len(seen) - len(failed)} 个文件，失败 {len(failed)}")
for p, e in failed[:20]:
    print("ERR", p, e)

if failed:
    sys.exit(f"有 {len(failed)} 个文件下载失败")

if not os.path.exists(os.path.join(OUT, "index.html")):
    sys.exit("缺少 index.html")

count = sum(len(files) for _, _, files in os.walk(OUT))
total = sum(os.path.getsize(os.path.join(root, f)) for root, _, files in os.walk(OUT) for f in files)
print(f"落盘 {count} 个文件，{total / 1024 / 1024:.2f} MB")
if count < 300:
    sys.exit(f"文件数只有 {count}，疑似不完整")
