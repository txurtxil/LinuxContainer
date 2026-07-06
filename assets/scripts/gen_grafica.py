#!/usr/bin/python3
import sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

def main():
    input_file, output_png = sys.argv[1], sys.argv[2]
    with open(input_file) as f:
        content = f.read().strip()
    labels, values = [], []
    for item in content.split(';'):
        if ':' not in item:
            continue
        label, value = item.rsplit(':', 1)
        labels.append(label.strip())
        try:
            values.append(float(value.strip()))
        except ValueError:
            values.append(0)
    plt.figure(figsize=(8, 5))
    plt.bar(labels, values, color='steelblue')
    plt.xticks(rotation=30, ha='right')
    plt.tight_layout()
    plt.savefig(output_png, dpi=100)

if __name__ == '__main__':
    main()
