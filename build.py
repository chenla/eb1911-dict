#!/usr/bin/env python3
"""Build a dictd database from the 1911 Encyclopaedia Britannica.

Source: https://github.com/dcampos/eb1911 release asset all.json.bz2 -- the
complete Wikisource transcription, rendered to HTML, rebuilt weekly.  39,288
JSON-lines records of {page, pageid, revid, content}.

Why not the Wikimedia dump or the API: EB1911 articles in Wikisource's main
namespace are only transclusion stubs --

    <pages index="EB1911 - Volume 25.djvu" from="1088" to="1088" ... />

-- with the text living in the Page: namespace, and prop=extracts returns zero
characters for them.  Resolving that is exactly the work dcampos/eb1911 already
does, so this consumes its output instead of redoing it.

Gutenberg's own transcription stalled at M in about 2013 (130 slices, A-M), which
is why it is not the source here.

    ./build.py            # expects data/all.json.bz2
"""
import bz2, html, json, os, re, subprocess, sys
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "data", "all.json.bz2")
PREFIX = "1911 Encyclopædia Britannica/"
NAME = "eb1911"

B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
BLOCK = {"p","div","br","li","tr","h1","h2","h3","h4","h5","h6",
         "dd","dt","blockquote","table","hr","pre"}
# subtrees that are apparatus, not article: Wikisource navigation, the header
# template, edit links, categories and the page-number markers from the scans
SKIP_CLASS = re.compile(r"ws-noexport|wst-header|wst-footer|mw-editsection|"
                        r"catlinks|navigation-not-searchable|pagenum|ws-pagenum|"
                        r"mw-references-columns|printfooter")
SKIP_TAG = {"style", "script", "sup"}

def b64(n):
    if n == 0:
        return B64[0]
    out = ""
    while n:
        out = B64[n & 63] + out
        n >>= 6
    return out

def sort_key(w):
    """dictd's index collation, determined experimentally.

    The server binary-searches the index, so it must be sorted exactly as dictd
    compares: fold ASCII case, drop ASCII punctuation, keep spaces, and keep
    non-ASCII bytes untouched, comparing bytes in the C locale.

    `LC_ALL=C sort -df` is close but wrong: -d drops accented letters, so
    "Vígfússon" sorts before "Vigil" while dictd -- which keeps the UTF-8 bytes,
    and 0xC3 > 'i' -- puts it after.  One mis-sorted neighbour makes the binary
    search miss, and a naive key (fold case, strip everything non-alphanumeric)
    failed 35 of 150 EB1911 lookups.
    """
    out = []
    for b in w.encode("utf8"):
        if b > 127:
            out.append(b)
        else:
            c = chr(b)
            if c.isalnum() or c == " ":
                out.append(ord(c.lower()))
    return bytes(out)

class ToText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.skip = 0          # depth of the subtree being skipped
        self.stack = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        skipping = tag in SKIP_TAG or SKIP_CLASS.search(a.get("class", "") or "")
        if self.skip:
            self.skip += 1
        elif skipping:
            self.skip = 1
        elif tag in BLOCK:
            self.out.append("\n")
        self.stack.append(tag)

    def handle_endtag(self, tag):
        if self.stack:
            self.stack.pop()
        if self.skip:
            self.skip -= 1
        elif tag in BLOCK:
            self.out.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.out.append(data)

    def text(self):
        s = "".join(self.out)
        s = s.replace(" ", " ")
        s = re.sub(r"[ \t]+", " ", s)
        s = re.sub(r" ?\n ?", "\n", s)
        s = re.sub(r"\n{3,}", "\n\n", s)
        return s.strip()

def to_text(h):
    p = ToText()
    p.feed(h)
    p.close()
    return p.text()

def records(path):
    skipped = {"volume index": 0, "root": 0, "odd title": 0, "empty": 0}
    with bz2.open(path, "rt", encoding="utf8") as f:
        for line in f:
            d = json.loads(line)
            page = d.get("page", "")
            if page == PREFIX.rstrip("/"):
                skipped["root"] += 1; continue
            if not page.startswith(PREFIX):
                skipped["odd title"] += 1; continue
            title = page[len(PREFIX):]
            if re.match(r"^Vol(ume)? \d+", title):
                skipped["volume index"] += 1; continue
            body = to_text(d.get("content") or "")
            if len(body) < 20:
                skipped["empty"] += 1; continue
            if "/" in title:                      # a section of a long article
                parent, child = title.split("/", 1)
                head = child.strip()
                body = f"(part of {parent})\n\n{body}"
            else:
                head = title.strip()
            if head:
                yield head, body
    for k, v in skipped.items():
        if v:
            print(f"  skipped {v} ({k})")

def main():
    if not os.path.exists(SRC):
        sys.exit(f"missing {SRC} -- run ./fetch-data.sh")
    dict_path = os.path.join(HERE, f"{NAME}.dict")
    idx_path = os.path.join(HERE, f"{NAME}.index")
    index = []
    with open(dict_path, "w", encoding="utf8") as f:
        def put(word, text):
            off = f.tell()
            f.write(text)
            index.append((word, off, f.tell() - off))
        put("00-database-short", "     Encyclopaedia Britannica, 11th Edition (1911)\n")
        put("00-database-url", "     https://en.wikisource.org/wiki/1911_Encyclop%C3%A6dia_Britannica\n")
        put("00-database-info",
            "     The Encyclopaedia Britannica, Eleventh Edition (1910-1911).\n"
            "     Public domain.  Text from the Wikisource transcription, via\n"
            "     https://github.com/dcampos/eb1911 (rebuilt weekly).\n"
            "     Proofread transcription, not OCR.\n")
        n = 0
        for head, body in records(SRC):
            put(head, head + "\n" + "\n".join("  " + l for l in body.split("\n")) + "\n")
            n += 1
    index.sort(key=lambda r: sort_key(r[0]))
    with open(idx_path, "w", encoding="utf8") as f:
        for word, off, ln in index:
            f.write(f"{word}\t{b64(off)}\t{b64(ln)}\n")
    subprocess.run(["dictzip", "-f", dict_path], check=True)
    print(f"  {n} articles")
    for p in (dict_path + ".dz", idx_path):
        print(f"  {os.path.basename(p):<20} {os.path.getsize(p)/1048576:.1f} MB")

if __name__ == "__main__":
    main()
