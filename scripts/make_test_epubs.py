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
