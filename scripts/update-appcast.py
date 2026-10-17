#!/usr/bin/env python3
"""Prepend a release <item> to appcast.xml (Sparkle feed served from main via raw.githubusercontent.com).

Usage: update-appcast.py APPCAST VERSION BUILD DOWNLOAD_URL SIGN_UPDATE_OUTPUT [MIN_MACOS]

SIGN_UPDATE_OUTPUT is the attribute string printed by Sparkle's sign_update, e.g.
  sparkle:edSignature="..." length="12345"
"""
import email.utils
import pathlib
import re
import sys
from xml.sax.saxutils import escape, quoteattr

EMPTY_FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PingStat</title>
    <link>https://github.com/malcomvetter/PingStat</link>
    <description>PingStat updates</description>
    <language>en</language>
  </channel>
</rss>
"""


def main() -> int:
    if len(sys.argv) not in (6, 7):
        print(__doc__, file=sys.stderr)
        return 2
    appcast, version, build, url, signed = sys.argv[1:6]
    min_macos = sys.argv[6] if len(sys.argv) == 7 else "14.0"

    sig = re.search(r'sparkle:edSignature="([^"]+)"', signed)
    length = re.search(r'length="(\d+)"', signed)
    if not sig or not length:
        print(f"error: could not parse sign_update output: {signed!r}", file=sys.stderr)
        return 1

    path = pathlib.Path(appcast)
    text = path.read_text() if path.exists() else EMPTY_FEED
    if f"<sparkle:version>{build}</sparkle:version>" in text:
        print(f"error: appcast already has build {build}", file=sys.stderr)
        return 1

    tag = f"v{version}"
    item = f"""    <item>
      <title>PingStat {escape(version)}</title>
      <link>https://github.com/malcomvetter/PingStat/releases/tag/{escape(tag)}</link>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(min_macos)}</sparkle:minimumSystemVersion>
      <enclosure url={quoteattr(url)} sparkle:edSignature={quoteattr(sig.group(1))} length="{length.group(1)}" type="application/octet-stream"/>
    </item>
"""
    marker = "    <language>en</language>\n"
    if marker not in text:
        print("error: appcast.xml is missing the <language> anchor line", file=sys.stderr)
        return 1
    path.write_text(text.replace(marker, marker + item, 1))
    print(f"==> appcast.xml: added {version} (build {build})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
