"""Build deterministic opkg packages on Windows or Linux; no SDK required for UI.

Backend directory must contain verified upstream Go binaries and the controller
built from warp-awg/files/warp-awgctl.c for aarch64-linux-musl (static).
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.1.13'
BACKEND_VERSION = '0.1.0'

def archive(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.GNU_FORMAT) as tar:
        parents = set()
        for name, _, _ in entries:
            parts = name.split('/')[:-1]
            for i in range(1, len(parts)+1): parents.add('/'.join(parts[:i]))
        for parent in sorted(parents):
            info = tarfile.TarInfo('./' + parent + '/')
            info.type, info.mode, info.uid, info.gid, info.mtime = tarfile.DIRTYPE, 0o755, 0, 0, 0
            info.uname = info.gname = 'root'
            tar.addfile(info)
        for name, data, mode in sorted(entries):
            info = tarfile.TarInfo('./' + name)
            info.size, info.mode, info.uid, info.gid, info.mtime = len(data), mode, 0, 0, 0
            info.uname = info.gname = 'root'
            tar.addfile(info, io.BytesIO(data))
    return gzip.compress(stream.getvalue(), mtime=0)

def package(out, name, arch, entries, depends, conffiles=(), version=VERSION):
    control = f'Package: {name}\nVersion: {version}\nArchitecture: {arch}\nMaintainer: moz9\nSection: net\nPriority: optional\nLicense: Apache-2.0 MIT\nDepends: {depends}\nInstalled-Size: {sum(len(data) for _, data, _ in entries)}\nDescription: Cloudflare WARP OpenWrt Podkop integration\n'
    controls = [('control', control.encode(), 0o644)]
    if conffiles:
        controls.append(('conffiles', ('\n'.join(conffiles)+'\n').encode(), 0o644))
    # OpenWrt opkg builds use gzip/tar as the outer IPK container, not Debian ar.
    result = archive([('debian-binary', b'2.0\n', 0o644),
                      ('control.tar.gz', archive(controls), 0o644),
                      ('data.tar.gz', archive(entries), 0o644)])
    dest = out / f'{name}_{version}_{arch}.ipk'
    dest.write_bytes(result)
    return dest

def build(backend, out):
    out.mkdir(parents=True, exist_ok=True)
    files = []
    installed = []
    sizes = []
    ui = ROOT / 'htdocs/luci-static/resources/view/warp/cfwarp.js'
    ui_data = ui.read_bytes().replace(b'\r\n', b'\n')
    view_name = 'warp/cfwarp_' + VERSION.replace('.', '_') + '_' + hashlib.sha256(ui_data).hexdigest()[:8]
    expected = {
        # Hashes of the Go binaries extracted from checksum-verified v3.0.0 APKs.
        # Controller is built from the modified source and checked on the target.
        'warp-amneziawg-go': '4f946e9ff2840e92160f4fa01cf493fb9e8df3853603fe8a9f8e45fc0fb1b857',
        'warp-warpscout': 'a5298bd9c526738729a2fa9cc462750c4e3e2b180fe446773e407580cf5c1eb1',
    }
    for package_name, names, deps in [
        ('warp-awg', ['warp-amneziawg-go', 'warp-awgctl'], 'kmod-tun'),
        ('warp-warpscout', ['warp-warpscout'], 'ca-bundle')]:
        entries = []
        for name in names:
            data = (backend / name).read_bytes()
            if data[:4] != b'\x7fELF' or data[4] != 2 or int.from_bytes(data[18:20], 'little') != 183:
                raise ValueError(f'{name}: expected ARM64 ELF')
            if name in expected and hashlib.sha256(data).hexdigest() != expected[name]:
                raise ValueError(f'{name}: unexpected backend hash')
            entries.append(('usr/libexec/' + name, data, 0o755))
            installed.append((f'/usr/libexec/{name}', data))
        files.append(package(out, package_name, 'aarch64_cortex-a53', entries, deps, version=BACKEND_VERSION))
        sizes.append((package_name, sum((len(data)+1023)//1024+4 for _, data, _ in entries)))
    entries = []
    for path in (ROOT / 'root').rglob('*'):
        if path.is_file():
            name = path.relative_to(ROOT / 'root').as_posix()
            mode = 0o755 if name.startswith(('usr/libexec/', 'etc/init.d/')) else 0o644
            if name == 'etc/config/warp': mode = 0o600
            data = path.read_bytes().replace(b'\r\n', b'\n')
            if name == 'usr/share/luci/menu.d/luci-app-warp.json':
                menu = json.loads(data)
                menu['admin/services/warp']['action']['path'] = view_name
                data = (json.dumps(menu, ensure_ascii=False, indent=2)+'\n').encode()
            entries.append((name, data, mode))
    # Themes may pin resource_version. A versioned filename prevents a stale UI.
    entries.append(('www/luci-static/resources/view/' + view_name + '.js', ui_data, 0o644))
    installed.extend(('/'+name, data) for name, data, _ in entries if not name.startswith('etc/config/'))
    files.append(package(out, 'luci-app-warp', 'all', entries,
                         'luci-base, rpcd-mod-ucode, curl, jsonfilter, warp-awg, warp-warpscout', ['/etc/config/warp']))
    sizes.append(('luci-app-warp', sum((len(data)+1023)//1024+4 for _, data, _ in entries)))
    (out / 'INSTALL-SIZES').write_text(''.join(f'{name} {size}\n' for name,size in sizes), encoding='ascii', newline='\n')
    (out / 'FILES.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {name}\n' for name, data in installed), encoding='ascii', newline='\n')
    checksummed = files + [out/'FILES.sha256', out/'INSTALL-SIZES']
    (out / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.name}\n' for f in checksummed), encoding='ascii', newline='\n')
    for f in files: print(f.name, f.stat().st_size)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--backend', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=ROOT / 'dist-podkop')
    args = parser.parse_args()
    build(args.backend, args.out)
