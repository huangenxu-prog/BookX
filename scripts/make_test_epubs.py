"""Generate synthetic EPUBs; no copyrighted books are checked in."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
root = Path(__file__).resolve().parents[1] / 'Tests' / 'Fixtures'
def book(name, bodies, nav='ncx'):
    with ZipFile(root / name, 'w', ZIP_DEFLATED) as z:
        z.writestr('mimetype', 'application/epub+zip')
        z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
        items = ''.join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(len(bodies)))
        if nav == 'ncx':
            items += '<item id="nav" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
            z.writestr('OPS/toc.ncx', '<ncx><navMap>'+''.join(f'<navPoint><navLabel><text>目录{i+1}</text></navLabel><content src="c{i}.xhtml#start"/></navPoint>' for i in range(len(bodies)))+'</navMap></ncx>')
        else:
            items += '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
            z.writestr('OPS/nav.xhtml', '<html><body><nav><ol>'+''.join(f'<li><a href="c{i}.xhtml#start">目录{i+1}</a></li>' for i in range(len(bodies)))+'</ol></nav></body></html>')
        z.writestr('OPS/book.opf', '<package><metadata><title>按需测试</title><creator>BookX Tests</creator></metadata><manifest>'+items+'</manifest><spine>'+''.join(f'<itemref idref="c{i}"/>' for i in range(len(bodies)))+'</spine></package>')
        for i, body in enumerate(bodies):
            z.writestr(f'OPS/c{i}.xhtml', body)
def text(i):
    return '<html><body><h1 id="start">章节'+str(i)+'</h1><p>'+('春天。👨‍👩‍👧‍👦é一起阅读！'*80)+'</p></body></html>'
book('lazy.epub', [text(0), '<html><body/></html>', text(2), '<html><broken>'])
book('nav3.epub', [text(0), text(1)], nav='nav')
book('large.epub', [text(i) for i in range(1836)])

# An illustration embedded between paragraphs, including a percent-encoded path.
with ZipFile(root / 'illustrated.epub', 'w', ZIP_DEFLATED) as z:
    z.writestr('mimetype', 'application/epub+zip')
    z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
    z.writestr('OPS/book.opf', '<package><metadata><title>图文测试</title></metadata><manifest><item id="c0" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/><item id="img" href="Images/figure%201.png" media-type="image/png"/></manifest><spine><itemref idref="c0"/></spine></package>')
    z.writestr('OPS/Text/chapter.xhtml', '<html><body><p>图前文字</p><img src="../Images/figure%201.png" alt="插图"/><p>图后文字</p></body></html>')
    z.writestr('OPS/Images/figure 1.png', bytes([137, 80, 78, 71, 13, 10, 26, 10]) + b'fixture')

# Valid EPUB 2/3 publications for the toolkit and WebKit compatibility tests.
import base64
for version in ['2.0', '3.0']:
    target = root / ('readium' + version[0] + '.epub')
    with ZipFile(target, 'w', ZIP_DEFLATED) as z:
        z.writestr('mimetype', 'application/epub+zip')
        z.writestr('META-INF/container.xml', '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        nav_item = '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' if version == '3.0' else ''
        z.writestr('OPS/book.opf', f'''<package xmlns="http://www.idpf.org/2007/opf" version="{version}" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:bookx:test</dc:identifier><dc:title>Readium 图文测试</dc:title><dc:language>zh-CN</dc:language><dc:creator>BookX</dc:creator><meta property="dcterms:modified">2026-11-18T00:00:00Z</meta></metadata>
          <manifest><item id="c1" href="one.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="two.xhtml" media-type="application/xhtml+xml"/><item id="css" href="style.css" media-type="text/css"/><item id="image" href="image.png" media-type="image/png"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>{nav_item}</manifest>
          <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine></package>''')
        z.writestr('OPS/toc.ncx', '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>测试</text></docTitle><navMap><navPoint id="one" playOrder="1"><navLabel><text>第一章</text></navLabel><content src="one.xhtml"/></navPoint><navPoint id="two" playOrder="2"><navLabel><text>第二章</text></navLabel><content src="two.xhtml"/></navPoint></navMap></ncx>')
        z.writestr('OPS/nav.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">第一章</a></li><li><a href="two.xhtml">第二章</a></li></ol></nav></body></html>')
        for name, text in [('one', '第一章图文'), ('two', '第二章正文')]:
            z.writestr(f'OPS/{name}.xhtml', f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{text}</title><link rel="stylesheet" href="style.css"/></head><body><p id="styled">{text}</p><img src="image.png" alt="图文测试插图"/></body></html>')
        z.writestr('OPS/style.css', '#styled { color: rgb(121, 33, 44); } img { width: 80px; height: 80px; }')
        z.writestr('OPS/image.png', base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII='))
