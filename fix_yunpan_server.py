from pathlib import Path
import re
import time

stamp = str(int(time.time()))
index = Path('/var/www/yunpan/index.html')
s = index.read_text(encoding='utf-8', errors='ignore')
index.with_name(f'index.html.bak-fix-{stamp}').write_text(s, encoding='utf-8')

if '<base href="/yunpan/">' not in s:
    s = s.replace('<head>', '<head>\n  <base href="/yunpan/">', 1)

s = re.sub(
    r'src="(?:/yunpan)?/assets/index-ig3RpFwq\.js(?:\?v=[0-9]+)?"',
    f'src="/yunpan/assets/index-ig3RpFwq.js?v={stamp}"',
    s,
)
s = re.sub(
    r'href="(?:/yunpan)?/assets/index-CLm3Cqis\.css(?:\?v=[0-9]+)?"',
    f'href="/yunpan/assets/index-CLm3Cqis.css?v={stamp}"',
    s,
)
index.write_text(s, encoding='utf-8')

js = Path('/var/www/yunpan/assets/index-ig3RpFwq.js')
js_text = js.read_text(encoding='utf-8', errors='ignore')
if 'history:Use("/yunpan/")' not in js_text:
    js.with_name(f'{js.name}.bak-route-{stamp}').write_text(js_text, encoding='utf-8')
    old = 'history:Use(),routes:mie'
    new = 'history:Use("/yunpan/"),routes:mie'
    if old not in js_text:
        raise SystemExit('route pattern not found')
    js.write_text(js_text.replace(old, new, 1), encoding='utf-8')

conf = Path('/etc/nginx/conf.d/yunpan.conf')
c = conf.read_text(encoding='utf-8', errors='ignore')
Path(f'/tmp/yunpan.conf.bak-fix-{stamp}').write_text(c, encoding='utf-8')

block_start = '    location = /yunpan/ {\n'
if block_start in c and 'no-cache, no-store, must-revalidate' not in c:
    c = c.replace(
        '        try_files /yunpan/index.html =404;\n',
        '        try_files /yunpan/index.html =404;\n'
        '        add_header Cache-Control "no-cache, no-store, must-revalidate";\n'
        '        add_header Pragma "no-cache";\n'
        '        add_header Expires "0";\n',
        1,
    )
    conf.write_text(c, encoding='utf-8')

print('STAMP', stamp)
print(index.read_text(encoding='utf-8'))
print('ROUTE_OK', 'history:Use("/yunpan/")' in js.read_text(encoding='utf-8', errors='ignore'))
