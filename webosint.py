#!/usr/bin/env python3
"""
webosint.py v3.0 — Servidor OSINT de búsqueda profunda
Puerto 9080 · paralelo (20 workers) · deadline 22s · discreto
"""
import http.server, json, os, re, sys, time, socket, hashlib, threading
import urllib.request, urllib.parse, urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from html import escape

socket.setdefaulttimeout(6)

# Throttle - máximo 6 requests HTTP simultáneos
_http_sem = threading.Semaphore(4)

HOST, PORT = "0.0.0.0", 9080
MAX_WORKERS = 15
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
CACHE_SIZE = 50
search_cache = {}
cache_lock = threading.Lock()

def http_get(url, timeout=6):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,*/*"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", errors="replace")
    except Exception:
        return ""

def http_status(url, timeout=5):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0

def extract_links(html):
    for m in re.finditer(r'<a\s+href="([^"]+)"\s+class="result-link"[^>]*>', html):
        yield m.group(1)

# ═══ Módulos de búsqueda ═══════════════════════════════════════════════════

def search_ddg_api(name):
    r = []
    q = urllib.parse.quote(name)
    d = http_get(f"https://api.duckduckgo.com/?q={q}&format=json&no_html=1&skip_disambig=1")
    if not d: return r
    try:
        j = json.loads(d)
        if j.get("AbstractText"):
            r.append({"src":"DDG/Abstract","url":f"https://duckduckgo.com/?q={q}","detail":j["AbstractText"][:300]})
        for t in j.get("RelatedTopics",[]):
            if t.get("Text"):
                r.append({"src":"DDG/Related","url":t.get("FirstURL",""),"detail":t["Text"][:200]})
        for x in j.get("Results",[]):
            if x.get("FirstURL"):
                r.append({"src":"DDG/Result","url":x["FirstURL"],"detail":x.get("Text","")[:200]})
    except: pass
    return r

def search_ddg_lite(name):
    r = []
    h = http_get(f"https://lite.duckduckgo.com/lite/?q={urllib.parse.quote(name)}")
    for url in extract_links(h):
        r.append({"src":"DDG/Lite","url":url,"detail":""})
        if len(r)>=12: break
    return r

def search_social(name):
    r = []
    q = urllib.parse.quote(name)
    sites = [
        ("LinkedIn",f"https://www.linkedin.com/search/results/all/?keywords={q}"),
        ("Twitter/X",f"https://twitter.com/search?q={q}&src=typed_query&f=user"),
        ("Facebook",f"https://www.facebook.com/search/people/?q={q}"),
        ("Instagram",f"https://www.instagram.com/web/search/topsearch/?query={q}"),
        ("TikTok",f"https://www.tiktok.com/search/user?q={q}"),
        ("Reddit",f"https://www.reddit.com/search/?q={q}&type=user"),
        ("YouTube",f"https://www.youtube.com/results?search_query={q}"),
        ("GitHub",f"https://github.com/search?q={q}&type=users"),
        ("Telegram",f"https://t.me/s?q={q}"),
        ("Pinterest",f"https://www.pinterest.com/search/users/?q={q}"),
        ("Medium",f"https://medium.com/search?q={q}"),
    ]
    with ThreadPoolExecutor(max_workers=11) as ex:
        fu = {ex.submit(http_status, u, 5): (n,u) for n,u in sites}
        for f in as_completed(fu):
            n,u = fu[f]
            try:
                if f.result() in (200,301,302):
                    r.append({"src":f"Social/{n}","url":u,"detail":"HTTP "+str(f.result())})
            except: pass
    return r

def search_username(uname):
    r = []
    sites = {
        "Twitter/X":f"https://twitter.com/{uname}","Instagram":f"https://www.instagram.com/{uname}",
        "GitHub":f"https://github.com/{uname}","Reddit":f"https://www.reddit.com/user/{uname}",
        "TikTok":f"https://www.tiktok.com/@{uname}","YouTube":f"https://www.youtube.com/@{uname}",
        "Facebook":f"https://www.facebook.com/{uname}","LinkedIn":f"https://www.linkedin.com/in/{uname}",
        "Pinterest":f"https://www.pinterest.com/{uname}","Twitch":f"https://www.twitch.tv/{uname}",
        "Medium":f"https://medium.com/@{uname}","Dev.to":f"https://dev.to/{uname}",
        "Keybase":f"https://keybase.io/{uname}","Patreon":f"https://www.patreon.com/{uname}",
        "ProductHunt":f"https://www.producthunt.com/@{uname}","Behance":f"https://www.behance.net/{uname}",
        "Dribbble":f"https://dribbble.com/{uname}","Flickr":f"https://www.flickr.com/people/{uname}",
        "VK":f"https://vk.com/{uname}","Steam":f"https://steamcommunity.com/id/{uname}",
        "Spotify":f"https://open.spotify.com/user/{uname}","Telegram":f"https://t.me/{uname}",
        "Pastebin":f"https://pastebin.com/u/{uname}","HackerNews":f"https://news.ycombinator.com/user?id={uname}",
        "StackOverflow":f"https://stackoverflow.com/users/?search={uname}","GitLab":f"https://gitlab.com/{uname}",
        "BitBucket":f"https://bitbucket.org/{uname}","WordPress":f"https://{uname}.wordpress.com",
        "Tumblr":f"https://{uname}.tumblr.com","About.me":f"https://about.me/{uname}",
        "Imgur":f"https://imgur.com/user/{uname}","Linktree":f"https://linktr.ee/{uname}",
        "BuyMeACoffee":f"https://buymeacoffee.com/{uname}","Kofi":f"https://ko-fi.com/{uname}",
        "Replit":f"https://replit.com/@{uname}","CodePen":f"https://codepen.io/{uname}",
        "HackTheBox":f"https://app.hackthebox.com/profile/{uname}","TryHackMe":f"https://tryhackme.com/p/{uname}",
        "Mastodon":f"https://mastodon.social/@{uname}","Snapchat":f"https://www.snapchat.com/add/{uname}",
    }
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        fu = {ex.submit(http_status, u, 4): (n,u) for n,u in sites.items()}
        for f in as_completed(fu):
            n,u = fu[f]
            try:
                if f.result() in (200,301,302):
                    r.append({"src":f"User/{n}","url":u,"detail":"HTTP "+str(f.result())})
            except: pass
    return r

def search_email(email):
    r = []
    h = hashlib.md5(email.lower().encode()).hexdigest()
    if http_status(f"https://www.gravatar.com/avatar/{h}?d=404", 4) == 200:
        r.append({"src":"Email/Gravatar","url":f"https://www.gravatar.com/{h}","detail":"Avatar encontrado"})
    domain = email.split("@")[-1]
    bd = http_get(f"https://haveibeenpwned.com/api/v3/breaches?domain={domain}")
    if bd:
        try:
            for b in json.loads(bd)[:5]:
                r.append({"src":"Email/HIBP","url":"https://haveibeenpwned.com/","detail":f"{b.get('Name','?')} - {b.get('BreachDate','?')}"})
        except: pass
    h2 = http_get(f"https://lite.duckduckgo.com/lite/?q={urllib.parse.quote('"'+email+'"')}")
    for url in extract_links(h2):
        r.append({"src":"Email/Web","url":url,"detail":""})
        if len([x for x in r if x["src"]=="Email/Web"])>=8: break
    return r

def search_phone(phone):
    r = []
    digits = re.sub(r'[^0-9]','',phone)
    q = urllib.parse.quote('"'+phone+'"')
    h = http_get(f"https://lite.duckduckgo.com/lite/?q={q}")
    for url in extract_links(h):
        r.append({"src":"Phone/Web","url":url,"detail":""})
        if len([x for x in r if x["src"]=="Phone/Web"])>=10: break
    wc = http_status(f"https://api.whatsapp.com/send?phone={digits}",4)
    if wc not in (0,404):
        r.append({"src":"Phone/WhatsApp","url":f"https://wa.me/{digits}","detail":f"HTTP {wc}"})
    tc = http_status(f"https://t.me/+{digits}",4)
    if tc in (200,302):
        r.append({"src":"Phone/Telegram","url":f"https://t.me/+{digits}","detail":f"HTTP {tc}"})
    return r

def search_news(name):
    r = []
    h = http_get(f"https://lite.duckduckgo.com/lite/?q={urllib.parse.quote(name)}+%28news%29")
    for url in extract_links(h):
        r.append({"src":"News","url":url,"detail":""})
        if len(r)>=10: break
    return r

def search_docs(name):
    r = []
    q = urllib.parse.quote('"'+name+'"')
    for ext in ("pdf","doc","docx","xls","xlsx","ppt","pptx","txt","csv","odt"):
        h = http_get(f"https://lite.duckduckgo.com/lite/?q={q}+filetype%3A{ext}")
        for url in extract_links(h):
            r.append({"src":f"Doc/{ext}","url":url,"detail":""})
            if len([x for x in r if x["src"]==f"Doc/{ext}"])>=3: break
    return r

def search_deep(name):
    r = []
    q = urllib.parse.quote('"'+name+'"')
    for tag,site in [("Pastebin",f"site:pastebin.com {q}"),("Hastebin",f"site:hastebin.com {q}"),
                     ("Foros/Reddit",f"site:reddit.com+OR+site:quora.com+OR+site:stackexchange.com {q}")]:
        h = http_get(f"https://lite.duckduckgo.com/lite/?q={urllib.parse.quote(site)}")
        for url in extract_links(h):
            r.append({"src":f"Deep/{tag}","url":url,"detail":""})
            if len([x for x in r if x["src"]==f"Deep/{tag}"])>=5: break
    return r

def search_domains(name):
    r = []
    clean = re.sub(r'[^a-z0-9]','',name.lower().replace(" ",""))
    if not clean: return r
    for tld in ("com","net","org","io","me","co","dev","app","info"):
        try:
            req = urllib.request.Request(f"https://rdap.verisign.com/com/v1/domain/{clean}.{tld}",headers={"User-Agent":UA})
            with urllib.request.urlopen(req, timeout=4) as resp:
                if resp.status==200:
                    r.append({"src":"Domain/"+tld,"url":f"https://{clean}.{tld}","detail":"REGISTRADO"})
        except: pass
    return r

# ═══ Módulos DEEP ══════════════════════════════════════════════════════════

def search_people_engines(name):
    r = []
    q = urllib.parse.quote('"'+name+'"')
    sites = [("PeekYou","peekyou.com"),("Pipl","pipl.com"),("Spokeo","spokeo.com"),
             ("Whitepages","whitepages.com"),("BeenVerified","beenverified.com"),
             ("Radaris","radaris.com"),("MyLife","mylife.com"),("ZabaSearch","zabasearch.com")]
    with ThreadPoolExecutor(max_workers=8) as ex:
        fu = {ex.submit(http_get, f"https://lite.duckduckgo.com/lite/?q=site%3A{site}+{q}"): name for name,site in sites}
        for f in as_completed(fu):
            src = fu[f]
            try:
                for url in extract_links(f.result()):
                    r.append({"src":f"Deep/People/{src}","url":url,"detail":""})
                    if len([x for x in r if f"People/{src}" in x["src"]])>=3: break
            except: pass
    return r

def search_archive(name):
    r = []
    q = urllib.parse.quote(f'site:web.archive.org "{name}"')
    h = http_get(f"https://lite.duckduckgo.com/lite/?q={q}")
    for url in extract_links(h):
        if "web.archive" in url:
            r.append({"src":"Deep/Archive","url":url,"detail":""})
            if len(r)>=8: break
    if not r:
        r.append({"src":"Deep/Archive","url":f"https://web.archive.org/web/*/{urllib.parse.quote(name)}",
                  "detail":"Buscar en Wayback Machine"})
    return r

def search_deep_dorks(name):
    r = []
    dorks = [f'"{name}" email OR correo OR mail', f'"{name}" telefono OR phone OR whatsapp',
             f'"{name}" direccion OR address OR domicilio', f'"{name}" curriculum OR cv OR resume',
             f'"{name}" site:docs.google.com', f'"{name}" site:pastebin.com',
             f'"{name}" site:linkedin.com', f'"{name}" site:facebook.com',
             f'"{name}" site:github.com', f'"{name}" site:wikipedia.org']
    with ThreadPoolExecutor(max_workers=10) as ex:
        fu = {ex.submit(http_get, f"https://lite.duckduckgo.com/lite/?q={urllib.parse.quote(d)}"): d for d in dorks}
        for f in as_completed(fu):
            d = fu[f]
            try:
                for url in extract_links(f.result()):
                    r.append({"src":"Deep/Dork","url":url,"detail":d[:60]})
                    if len([x for x in r if x.get("detail")==d[:60]])>=3: break
            except: pass
    return r

def search_blogs(name):
    r = []
    clean = re.sub(r'[^a-z0-9]','',name.lower().replace(" ",""))
    if not clean or len(clean)<3: return r
    platforms = [("Blogger",f"https://{clean}.blogspot.com"),("WordPress",f"https://{clean}.wordpress.com"),
                 ("Tumblr",f"https://{clean}.tumblr.com"),("About.me",f"https://about.me/{clean}"),
                 ("Linktree",f"https://linktr.ee/{clean}"),("Carrd",f"https://{clean}.carrd.co"),
                 ("GitHub-Pages",f"https://{clean}.github.io")]
    with ThreadPoolExecutor(max_workers=7) as ex:
        fu = {ex.submit(http_status, u, 4): (n,u) for n,u in platforms}
        for f in as_completed(fu):
            n,u = fu[f]
            try:
                if f.result()==200:
                    r.append({"src":f"Deep/Blog/{n}","url":u,"detail":"Perfil personal"})
            except: pass
    return r

def search_variants(name):
    r = []
    parts = name.lower().strip().split()
    if len(parts)<2: return r
    main = parts[0]+parts[-1]
    r.append({"src":"Deep/Variant","url":"","detail":f"Variante: {main}"})
    with ThreadPoolExecutor(max_workers=2) as ex:
        def check(p,u):
            c = http_status(u,3)
            return (p,u,c)
        f1 = ex.submit(check,"GitHub",f"https://github.com/{main}")
        f2 = ex.submit(check,"Twitter",f"https://twitter.com/{main}")
        for f in [f1,f2]:
            try:
                p,u,c = f.result()
                if c==200:
                    r.append({"src":f"Deep/Variant/{p}","url":u,"detail":f"Usuario: {main}"})
            except: pass
    return r

def search_public_records(name):
    r = []
    q = urllib.parse.quote('"'+name+'"')
    searches = [("Patents","patents.google.com"),("Scholar","scholar.google.com"),
                ("OpenCorps","opencorporates.com"),("Crunchbase","crunchbase.com"),
                ("AngelList","angellist.com")]
    with ThreadPoolExecutor(max_workers=5) as ex:
        fu = {ex.submit(http_get, f"https://lite.duckduckgo.com/lite/?q=site%3A{site}+{q}"): name for name,site in searches}
        for f in as_completed(fu):
            src = fu[f]
            try:
                for url in extract_links(f.result()):
                    r.append({"src":f"Deep/Records/{src}","url":url,"detail":""})
                    if len([x for x in r if f"Records/{src}" in x["src"]])>=3: break
            except: pass
    return r

def search_cached_pages(name):
    r = []
    q = urllib.parse.quote('"'+name+'"')
    r.append({"src":"Deep/Cache","url":f"http://webcache.googleusercontent.com/search?q=cache:{q}",
              "detail":"Google Cache (click para ver)"})
    r.append({"src":"Deep/Cache","url":f"https://web.archive.org/web/*/{q}",
              "detail":"Wayback Machine"})
    return r

def search_image_reverse_hint(name):
    r = []
    q = urllib.parse.quote('"'+name+'"')
    h = http_get(f"https://lite.duckduckgo.com/lite/?q={q}+image")
    for url in extract_links(h):
        r.append({"src":"Deep/Images","url":url,"detail":""})
        if len([x for x in r if x["src"]=="Deep/Images"])>=8: break
    r.append({"src":"Deep/Images/Tools","url":"https://images.google.com/","detail":"Reverse image: Google"})
    r.append({"src":"Deep/Images/Tools","url":"https://tineye.com/","detail":"Reverse image: TinEye"})
    return r

def search_emailrep(email):
    r = []
    try:
        req = urllib.request.Request(f"https://emailrep.io/{urllib.parse.quote(email)}",
                                     headers={"User-Agent":UA,"Accept":"application/json"})
        with urllib.request.urlopen(req, timeout=6) as resp:
            j = json.loads(resp.read().decode())
            if j.get("email"):
                parts = []
                if j.get("reputation"): parts.append(f"reputación: {j['reputation']}")
                if j.get("suspicious"): parts.append("sospechoso")
                if j.get("details",{}).get("credentials_leaked"): parts.append("filtrado")
                if j.get("details",{}).get("spam"): parts.append("spam")
                r.append({"src":"Deep/EmailRep","url":f"https://emailrep.io/{email}",
                          "detail":" · ".join(parts) if parts else str(j.get("scores",{}))})
    except: pass
    return r

def search_phone_deep(phone):
    r = []
    digits = re.sub(r'[^0-9]','',phone)
    cc = {"1":"EE.UU./Canadá","34":"España","44":"Reino Unido","52":"México",
          "54":"Argentina","55":"Brasil","57":"Colombia","51":"Perú",
          "56":"Chile","58":"Venezuela","33":"Francia","49":"Alemania",
          "39":"Italia","81":"Japón","86":"China","91":"India"}
    for pref, pais in cc.items():
        if digits.startswith(pref):
            r.append({"src":"Deep/Phone/Prefijo","url":"","detail":f"País: {pais} (+{pref})"})
            break
    q = urllib.parse.quote(f'"{phone}" "phone" OR "teléfono" OR "contact"')
    h = http_get(f"https://lite.duckduckgo.com/lite/?q={q}")
    for url in extract_links(h):
        r.append({"src":"Deep/Phone/Directorios","url":url,"detail":""})
        if len([x for x in r if x["src"]=="Deep/Phone/Directorios"])>=10: break
    return r

def search_social_extra(name):
    r = []
    q = urllib.parse.quote(name)
    extras = [("Mastodon",f"https://mastodon.social/search?q={q}"),
              ("Telegram",f"https://t.me/s?q={q}"),
              ("Keybase",f"https://keybase.io/search?q={q}"),
              ("HackerOne",f"https://hackerone.com/{urllib.parse.quote(name.lower().replace(' ',''))}")]
    with ThreadPoolExecutor(max_workers=4) as ex:
        fu = {ex.submit(http_status, u, 4): (n,u) for n,u in extras}
        for f in as_completed(fu):
            n,u = fu[f]
            try:
                if f.result() in (200,301,302):
                    r.append({"src":f"Deep/Social/{n}","url":u,"detail":""})
            except: pass
    return r

# ═══ Orquestador con deadline ══════════════════════════════════════════════

def run_search(params):
    """Ejecuta módulos con prioridad: rápidos primero, deadline 8s."""
    results = []
    generated_emails = []
    DEADLINE = time.time() + 8

    name = params.get("name","").strip()
    username = params.get("username","").strip()
    email = params.get("email","").strip()
    phone = params.get("phone","").strip()

    if name and not email:
        clean = re.sub(r'[^a-z0-9]','',name.lower().replace(" ",""))
        for dom in ("gmail.com","yahoo.com","hotmail.com","outlook.com","protonmail.com"):
            generated_emails.append({"src":"Email/Generado","url":"","detail":f"{clean}@{dom}"})

    def safe(fn,*a,**kw):
        if time.time() > DEADLINE: return []
        try: return fn(*a,**kw)
        except: return []

    with ThreadPoolExecutor(max_workers=10) as ex:
        tasks = []
        # Fase 1: módulos rápidos (sin DDG)
        if name:
            tasks.append(ex.submit(safe, search_ddg_api, name))
            tasks.append(ex.submit(safe, search_social, name))
            tasks.append(ex.submit(safe, search_blogs, name))
            tasks.append(ex.submit(safe, search_variants, name))
            tasks.append(ex.submit(safe, search_cached_pages, name))
            tasks.append(ex.submit(safe, search_domains, name))
            tasks.append(ex.submit(safe, search_social_extra, name))
        if username:
            tasks.append(ex.submit(safe, search_username, username))
        if email:
            tasks.append(ex.submit(safe, search_email, email))
            tasks.append(ex.submit(safe, search_emailrep, email))
        if phone:
            tasks.append(ex.submit(safe, search_phone_deep, phone))
            tasks.append(ex.submit(safe, search_phone, phone))

        # Primera ronda: recolectar resultados rápidos
        for f in as_completed(tasks):
            if time.time() > DEADLINE: break
            try:
                res = f.result(timeout=4)
                if res: results.extend(res)
            except: pass

        # Fase 2: módulos DDG (solo si queda tiempo)
        if time.time() < DEADLINE - 2 and name:
            more = []
            more.append(ex.submit(safe, search_ddg_lite, name))
            more.append(ex.submit(safe, search_news, name))
            more.append(ex.submit(safe, search_docs, name))
            more.append(ex.submit(safe, search_deep, name))
            more.append(ex.submit(safe, search_people_engines, name))
            more.append(ex.submit(safe, search_archive, name))
            more.append(ex.submit(safe, search_deep_dorks, name))
            more.append(ex.submit(safe, search_public_records, name))
            more.append(ex.submit(safe, search_image_reverse_hint, name))
            for f in as_completed(more):
                if time.time() > DEADLINE: break
                try:
                    res = f.result(timeout=4)
                    if res: results.extend(res)
                except: pass

    if generated_emails: results.extend(generated_emails)
    results.sort(key=lambda r: r.get("src",""))
    seen = set()
    unique = []
    for r in results:
        u = r.get("url","")
        if u and u not in seen:
            seen.add(u); unique.append(r)
        elif not u: unique.append(r)
    return unique

# ═══ Servidor HTTP ═════════════════════════════════════════════════════════

HTML_PAGE = """<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OSINT · búsqueda profunda</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0d0d1a;color:#c0c0d0;font-family:'Segoe UI',system-ui,sans-serif;min-height:100vh}
.container{max-width:1100px;margin:0 auto;padding:20px}
header{padding:20px 0;border-bottom:1px solid #1a1a3a;margin-bottom:30px;display:flex;align-items:center;gap:12px}
header h1{font-weight:300;font-size:22px;letter-spacing:2px;color:#8888aa}
header span{color:#4a4a6a;font-size:13px}.badge{background:#1a2a1a;border:1px solid #2a4a2a;color:#4a8;padding:2px 10px;border-radius:4px;font-size:10px;margin-left:8px}
.card{background:#12122a;border:1px solid #1e1e3e;border-radius:10px;padding:24px;margin-bottom:20px}
.form-grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.form-group label{display:block;font-size:11px;color:#6666aa;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px}
.form-group input{width:100%;padding:10px 14px;background:#0a0a1a;border:1px solid #1e1e3e;border-radius:6px;color:#d0d0e0;font-size:14px;outline:none;transition:border-color .2s}
.form-group input:focus{border-color:#4a4a8a}
.form-group input::placeholder{color:#3a3a5a}
.form-actions{display:flex;gap:12px;margin-top:18px;align-items:center}
.btn{background:#2a2a5a;border:none;color:#b0b0d0;padding:10px 28px;border-radius:6px;font-size:14px;cursor:pointer;transition:all .2s;font-weight:500}
.btn:hover{background:#3a3a7a;color:#fff}
.btn-primary{background:#3a3a7a;color:#d0d0f0}
.btn-primary:hover{background:#5a5aaa}
.btn:disabled{opacity:.4;cursor:not-allowed}
.spinner{display:none;width:18px;height:18px;border:2px solid #3a3a6a;border-top-color:#8888cc;border-radius:50%;animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.status-bar{display:flex;align-items:center;gap:10px;font-size:13px;color:#666}
.results-count{font-size:13px;color:#8888bb;margin-bottom:14px;display:flex;justify-content:space-between;flex-wrap:wrap}
.result-item{display:flex;align-items:flex-start;gap:12px;padding:10px 12px;border-bottom:1px solid #181838;transition:background .15s}
.result-item:hover{background:#161632}
.result-item:last-child{border-bottom:none}
.result-icon{width:24px;height:24px;border-radius:50%;background:#1e1e3e;display:flex;align-items:center;justify-content:center;font-size:10px;flex-shrink:0;color:#555}
.result-icon.found{background:#1a3a2a;color:#4a8}
.result-content{flex:1;min-width:0}
.result-src{font-size:10px;color:#4a4a7a;text-transform:uppercase;letter-spacing:.5px;margin-bottom:2px}
.result-url{color:#6a6aaa;font-size:12px;word-break:break-all;text-decoration:none;display:block;margin-bottom:2px;font-family:monospace}
.result-url:hover{color:#8888cc;text-decoration:underline}
.result-detail{font-size:11px;color:#5a5a7a;line-height:1.3}
.empty-state{text-align:center;padding:40px;color:#4a4a6a;font-size:14px}
.empty-state .icon{font-size:40px;margin-bottom:10px;opacity:.3}
.footer{text-align:center;padding:30px 0;font-size:11px;color:#3a3a5a}
@media(max-width:600px){.form-grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="container">
<header>
<h1>◈ búsqueda<span class="badge">profunda</span></h1>
<span>OSINT · 22s · 20 workers · 16 módulos</span>
</header>
<div class="card">
<form id="searchForm" autocomplete="off">
<div class="form-grid">
<div class="form-group"><label for="name">Nombre</label>
<input type="text" id="name" name="name" placeholder="ej: Juan Pérez" autofocus></div>
<div class="form-group"><label for="username">Usuario</label>
<input type="text" id="username" name="username" placeholder="ej: juanperez80"></div>
<div class="form-group"><label for="email">Email</label>
<input type="email" id="email" name="email" placeholder="ej: juan@correo.com"></div>
<div class="form-group"><label for="phone">Teléfono</label>
<input type="text" id="phone" name="phone" placeholder="ej: +525512345678"></div>
</div>
<div class="form-actions">
<button type="submit" class="btn btn-primary" id="searchBtn">🔍 Buscar</button>
<div class="spinner" id="spinner"></div>
<div class="status-bar" id="statusBar"></div>
</div>
</form>
</div>
<div class="card" id="resultsCard">
<div class="results-count" id="resultsCount">Completa al menos un campo</div>
<div id="resultsContainer">
<div class="empty-state"><div class="icon">◈</div><div>Búsqueda OSINT profunda · 16 módulos paralelos</div></div>
</div>
</div>
<div class="footer">webosint v3.0 · respeta privacidad y leyes · solo uso autorizado</div>
</div>
<script>
const form=document.getElementById('searchForm'),btn=document.getElementById('searchBtn'),
spinner=document.getElementById('spinner'),statusBar=document.getElementById('statusBar'),
resultsCount=document.getElementById('resultsCount'),rc=document.getElementById('resultsContainer');
form.addEventListener('submit',async e=>{
e.preventDefault();const fd=new FormData(form),params=new URLSearchParams(fd);
let has=false;for(const[,v] of fd){if(v.trim())has=true}
if(!has){statusBar.textContent='Completa al menos un campo';return}
btn.disabled=true;spinner.style.display='block';statusBar.textContent='Buscando...';
rc.innerHTML='<div class="loading-state"><div class="spinner" style="display:block;margin:0 auto 12px"></div><div style="color:#666">Escaneando 16 módulos OSINT...</div></div>';
resultsCount.textContent='Buscando...';const t0=Date.now();
try{
const resp=await fetch('/api/search',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:params});
const data=await resp.json();const sec=((Date.now()-t0)/1000).toFixed(1);
if(data.error){rc.innerHTML='<div class="empty-state"><div class="icon">\\u26a0</div>'+esc(data.error)+'</div>';resultsCount.textContent='Error';statusBar.textContent='Error';return}
const res=data.results||[],cats={};
res.forEach(r=>{const c=r.src.split('/')[0];cats[c]=(cats[c]||0)+1});
const summary=Object.entries(cats).sort((a,b)=>b[1]-a[1]).map(([k,v])=>k+'='+v).join(' \\u00b7 ');
if(res.length===0){rc.innerHTML='<div class="empty-state"><div class="icon">\\u25c7</div><div>Sin resultados p\\u00fablicos</div></div>';resultsCount.textContent='0 en '+sec+'s'}
else{rc.innerHTML=res.map(r=>'<div class="result-item"><div class="result-icon found">\\u2713</div><div class="result-content"><div class="result-src">'+esc(r.src)+(r.url?'</div><a class="result-url" href="'+esc(r.url)+'" target="_blank" rel="noopener">'+esc(r.url):'</div><span class="result-url">'+esc(r.detail))+'</a>'+(r.detail&&r.url?'<div class="result-detail">'+esc(r.detail)+'</div>':'')+'</div></div>').join('');resultsCount.textContent=res.length+' resultados en '+sec+'s \\u00b7 '+summary}
statusBar.textContent='\\u2714 '+res.length+' hallazgos'
}catch(err){rc.innerHTML='<div class="empty-state"><div class="icon">\\u2717</div><div>Error: '+esc(err.message)+'</div></div>';resultsCount.textContent='Error';statusBar.textContent='Error de red'}
btn.disabled=false;spinner.style.display='none';setTimeout(()=>{statusBar.textContent=''},4000)
});
function esc(s){if(!s)return'';return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
</script>
</body></html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=="/" or self.path=="/index.html":
            self.send_response(200)
            self.send_header("Content-Type","text/html;charset=utf-8")
            self.send_header("Server","webosint"); self.end_headers()
            self.wfile.write(HTML_PAGE.encode("utf-8"))
        elif self.path=="/health":
            self._json({"status":"ok","time":datetime.now().isoformat()})
        elif self.path=="/stats":
            self._json({"cache_size":len(search_cache),"workers":MAX_WORKERS,"timeout":6})
        elif self.path=="/favicon.ico":
            self.send_response(204); self.end_headers()
        else: self.send_response(404); self._json({"error":"not found"})

    def do_POST(self):
        if self.path!="/api/search":
            self._json({"error":"not found"},404); return
        clen=int(self.headers.get("Content-Length",0))
        body=self.rfile.read(clen).decode("utf-8","replace")
        params=urllib.parse.parse_qs(body,keep_blank_values=True)
        p={k:v[0] if v else"" for k,v in params.items()}
        if not any(p.get(k,"").strip() for k in ("name","username","email","phone")):
            self._json({"error":"Completa al menos un campo"}); return
        ck=f"{p.get('name','')}|{p.get('username','')}|{p.get('email','')}|{p.get('phone','')}"
        with cache_lock:
            if ck in search_cache: self._json(search_cache[ck]); return
        resp={"results":run_search(p),"count":0,"time":datetime.now().isoformat()}
        resp["count"]=len(resp["results"])
        with cache_lock:
            if len(search_cache)>CACHE_SIZE: search_cache.clear()
            search_cache[ck]=resp
        self._json(resp)

    def _json(self,data,code=200):
        self.send_response(code)
        self.send_header("Content-Type","application/json;charset=utf-8")
        self.send_header("Server","webosint")
        self.send_header("Access-Control-Allow-Origin","*")
        self.end_headers()
        self.wfile.write(json.dumps(data,ensure_ascii=False).encode("utf-8"))

    def log_message(self,fmt,*args):
        if len(args)>=2:
            c=str(args[1])
            if c.isdigit() and int(c)>=400:
                sys.stderr.write(f"[{datetime.now().strftime('%H:%M:%S')}] {c} {args[0]}\n")

def main():
    server=http.server.HTTPServer((HOST,PORT),Handler)
    print(f"\n  \\u25c6 webosint v3.0  \\u00b7  http://localhost:{PORT}",flush=True)
    print(f"  \\u25c6 {len([x for x in dir() if x.startswith('search_')])} m\\u00f3dulos  \\u00b7  {MAX_WORKERS} workers  \\u00b7  socket timeout 6s\n",flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt:
        print("\n  \\u25a0 servidor detenido",flush=True); server.server_close()

if __name__=="__main__": main()
