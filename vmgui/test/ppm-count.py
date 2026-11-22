#!/usr/bin/python3 -I
"""Count pixels in a binary PPM (grim -t ppm) for the vmgui e2e (lab only).

    ppm-count.py <file> eq <rrggbb>    # pixels of exactly this color
    ppm-count.py <file> red <rr>       # pixels whose red channel is <rr>
"""
import sys


def main():
    path, mode, arg = sys.argv[1:4]
    data = open(path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos)
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    pix = data[pos + 1:]
    if mode == "eq":
        want = bytes.fromhex(arg)
        n = sum(1 for i in range(0, len(pix) - 2, 3) if pix[i:i + 3] == want)
    elif mode == "red":
        r = int(arg, 16)
        n = pix[0::3].count(r)
    else:
        sys.exit(f"unknown mode {mode}")
    print(n)


if __name__ == "__main__":
    main()
