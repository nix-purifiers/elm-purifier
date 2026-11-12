# SPDX-License-Identifier: MIT
"""Finishes the package cache of an ELM_HOME from unpacked packages.

    python3 elm-home.py HOME COMPILER_VERSION PACKAGES

PACKAGES has one line per package, `author/project/version`, and each one
is unpacked at HOME/COMPILER_VERSION/packages/author/project/version. The
Elm compiler keeps only elm.json, LICENSE, README.md and src/ of a
downloaded package, so this removes everything else.

The compiler also reads packages/registry.dat, its copy of the package
server's list of every published version. That list changes with every
release, so it cannot be locked. This writes a registry that lists only
the locked versions, which is all an offline build resolves against.
"""

import os
import shutil
import struct
import sys

KEPT = ("elm.json", "LICENSE", "README.md", "src")


def trim(directory):
    """Removes what the compiler leaves out of a downloaded package."""
    for name in os.listdir(directory):
        if name not in KEPT:
            path = os.path.join(directory, name)
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path)
            else:
                os.remove(path)


# The registry is the compiler's Data.Binary encoding of
#   Registry { count :: Int, versions :: Map Name KnownVersions }
# Int is 8 bytes big-endian; a Map is its size followed by its entries in
# key order; a Name is author and project, each a length byte and UTF-8;
# KnownVersions is the newest version followed by a list (length, then
# elements) of older ones; a version is three bytes, or 255 followed by
# three 16-bit numbers when a part does not fit in a byte.


def encode_int(n):
    return struct.pack(">q", n)


def encode_text(text):
    data = text.encode()
    return bytes([len(data)]) + data


def encode_version(version):
    parts = [int(p) for p in version.split(".")]
    if all(p < 255 for p in parts):
        return bytes(parts)
    return b"\xff" + b"".join(struct.pack(">H", p) for p in parts)


def version_key(version):
    return tuple(int(p) for p in version.split("."))


def registry(packages):
    by_name = {}
    for package in packages:
        author, project, version = package.split("/")
        by_name.setdefault((author, project), []).append(version)
    data = encode_int(len(packages)) + encode_int(len(by_name))
    for author, project in sorted(by_name):
        versions = sorted(by_name[(author, project)], key=version_key, reverse=True)
        data += encode_text(author) + encode_text(project)
        data += encode_version(versions[0])
        data += encode_int(len(versions) - 1)
        data += b"".join(encode_version(v) for v in versions[1:])
    return data


def main(home, compiler_version, package_list):
    root = os.path.join(home, compiler_version, "packages")
    with open(package_list) as f:
        packages = [line.strip() for line in f if line.strip()]
    for package in packages:
        trim(os.path.join(root, package))
    with open(os.path.join(root, "registry.dat"), "wb") as f:
        f.write(registry(packages))


if __name__ == "__main__":
    main(*sys.argv[1:])
