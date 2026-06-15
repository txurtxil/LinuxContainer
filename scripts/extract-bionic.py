import subprocess, sys, os, gzip, re

def extract_ar_data(deb_data, filename):
    """Extract a file from ar archive by name."""
    if deb_data[:8] != b'!<arch>\n':
        return None
    pos = 8
    while pos + 60 <= len(deb_data):
        name = deb_data[pos:pos+16].decode('ascii', errors='replace').strip().rstrip('/')
        sz = int(deb_data[pos+48:pos+58].decode('ascii').strip())
        if name == filename or name == '/' + filename:
            return deb_data[pos+60:pos+60+sz]
        pos += 60 + sz + (sz % 2)
    return None

def parse_packages_index(path):
    """Parse Packages.gz/index to get {pkg: filename} mapping."""
    pkgs = {}
    current = {}
    with gzip.open(path, 'rt') if path.endswith('.gz') else open(path, 'rt') as f:
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
    
    pkgs = parse_packages_index(packages_file)
    
    if pkg_name not in pkgs:
        print(f"{pkg_name}: no encontrado")
        return 1
    
    filename = pkgs[pkg_name]
    url = f"https://packages.termux.org/apt/termux-main/{filename}"
    debname = os.path.basename(filename)
    
    print(f"{pkg_name}: {url}")
    
    # Download
    import urllib.request
    try:
        with urllib.request.urlopen(url) as resp:
            deb_data = resp.read()
    except Exception as e:
        print(f"  download fail: {e}")
        return 1
    
    # Extract data.tar.xz or .gz from ar
    for ext in ['xz', 'gz']:
        tar_name = f'data.tar.{ext}'
        tar_data = extract_ar_data(deb_data, tar_name)
        if tar_data:
            print(f"  found {tar_name} ({len(tar_data)} bytes)")
            break
    else:
        print(f"  data.tar not found in ar archive")
        return 1
    
    # Decompress and extract
    try:
        if ext == 'xz':
            r = subprocess.run(['xz', '-d'], input=tar_data, capture_output=True)
            tar_decoded = r.stdout
        elif ext == 'gz':
            tar_decoded = gzip.decompress(tar_data)
        
        # Extract tar
        subprocess.run(['tar', '-x', '-C', output_dir], input=tar_decoded, capture_output=True)
        print(f"  -> OK")
        return 0
    except Exception as e:
        print(f"  extract fail: {e}")
        return 1

if __name__ == '__main__':
    sys.exit(main())
