"""Fetch the pinned upstream model at build time; the app itself never downloads it."""
import hashlib
import pathlib
import shutil
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
NAME = 'kokoro-int8-multi-lang-v1_1'
SHA256 = '259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c'
URL = f'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/{NAME}.tar.bz2'
CACHE = ROOT / '.model-cache'
DEST = ROOT / 'Models' / 'Kokoro'
CACHE.mkdir(exist_ok=True)
archive = CACHE / (NAME + '.tar.bz2')
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()
if not archive.exists() or digest(archive) != SHA256:
    temp = archive.with_suffix('.download')
    with urllib.request.urlopen(URL, timeout=120) as response, temp.open('wb') as output:
        shutil.copyfileobj(response, output)
    if digest(temp) != SHA256:
        temp.unlink()
        raise RuntimeError('Kokoro model checksum mismatch; refusing changed upstream assets')
    temp.replace(archive)
marker = DEST / 'bookx-model.sha256'
if not marker.exists() or marker.read_text().strip() != SHA256:
    staging = CACHE / 'unpack'
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir()
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            path = (staging / member.name).resolve()
            if not path.is_relative_to(staging.resolve()) or member.issym() or member.islnk():
                raise RuntimeError('Unexpected archive path or link')
        tar.extractall(staging)
    shutil.rmtree(DEST, ignore_errors=True)
    DEST.parent.mkdir(exist_ok=True)
    shutil.move(str(staging / NAME), DEST)
    marker.write_text(SHA256 + '\n')
for name in ['model.int8.onnx', 'voices.bin', 'tokens.txt', 'lexicon-zh.txt', 'lexicon-us-en.txt', 'LICENSE']:
    assert (DEST / name).is_file(), name
print('Kokoro resources verified:', sum(p.stat().st_size for p in DEST.rglob('*') if p.is_file()), 'bytes')
