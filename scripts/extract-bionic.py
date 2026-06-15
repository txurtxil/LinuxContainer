import subprocess, sys, os, gzip, re

def extract_ar_data(deb_data, filename):
    if deb_data[:8] != b'!<arch>\n':
        return None
    pos = 8
    while pos + 60 <= len(deb_data):
        name = deb_data[pos:pos+16].decode('ascii', errors='replace').strip().rstrip('/')
        sz = int(deb_data[pos+48:pos+58].decode('ascii').strip())
        if name == filename:
            return deb_data[pos+60:pos+60+sz]
        pos += 60 + sz + (sz % 2)
    return None

def parse_packages(path):
    pkgs = {}
    current = {}
    open_func = gzip.open if path.endswith('.gz') else open
    with open_func(path, 'rt') as f:
        for line in f:
            line = line.rstrip()
            if not line:
                if 'Package' in current and 'Filename' in current:
                    pkgs[current['Package']] = current['Filename']
                current = {}
                continue
            m = re.match(r'^(\S+):\s*(.*)', line)
            if m:
                current[m.group(1)] = m.group(2)
    if 'Package' in current and 'Filename' in current:
        pkgs[current['Package']] = current['Filename']
    return pkgs

def main():
    pkg_name = sys.argv[1]
    output_dir = sys.argv[2]
    packages_file = sys.argv[3]

    pkgs = parse_packages(packages_file)
    if pkg_name not in pkgs:
        print(f"{pkg_name}: no encontrado")
        return 1

    filename = pkgs[pkg_name]
    url = f"https://packages.termux.org/apt/termux-main/{filename}"
    print(f"{pkg_name}: {url}")

    # Download with User-Agent
    import urllib.request
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=60) as resp:
            deb_data = resp.read()
        print(f"  descargado: {len(deb_data)} bytes")
    except Exception as e:
        print(f"  download fail: {e}")
        return 1

    # Find data.tar.xz
    tar_data = None
    for ext in ['xz', 'gz']:
        tar_data = extract_ar_data(deb_data, f'data.tar.{ext}')
        if tar_data:
            compression = ext
            print(f"  encontrado: data.tar.{ext} ({len(tar_data)} bytes)")
            break

    if not tar_data:
        print(f"  data.tar no encontrado en ar")
        return 1

    # Decompress and extract
    try:
        if compression == 'xz':
            r = subprocess.run(['xz', '-d'], input=tar_data, capture_output=True, timeout=30)
            tar_decoded = r.stdout
        else:
            tar_decoded = gzip.decompress(tar_data)

        subprocess.run(['tar', '-x', '-C', output_dir], input=tar_decoded, capture_output=True, timeout=30)
        print(f"  -> extraido OK")
        return 0
    except Exception as e:
        print(f"  extract fail: {e}")
        return 1

if __name__ == '__main__':
    sys.exit(main())
