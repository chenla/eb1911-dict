#!/bin/bash
# Install EB1911 into the local dictd, and add a 'words' virtual database so that
# ordinary word lookups do not drag a 40-page encyclopaedia article along.
#
# Not installed into /usr/share/dictd: Debian's dictdconfig rescans that directory
# and regenerates /var/lib/dictd/db.list, so anything there gets a plain stanza we
# cannot annotate.  /usr/local/share/dictd + an explicit stanza in dictd.conf is
# stable across dict-* package installs.
#   sudo bash ~/proj/britannica/install.sh
set -e
[ "$EUID" -eq 0 ] || { echo "needs root: sudo bash $0" >&2; exit 1; }
cd "$(dirname "$0")"
for f in eb1911.dict.dz eb1911.index; do
  [ -s "$f" ] || { echo "missing $f -- run ./build.py first" >&2; exit 1; }
done
install -d /usr/local/share/dictd
install -m 644 eb1911.dict.dz eb1911.index /usr/local/share/dictd/

CONF=/etc/dictd/dictd.conf
MARK="# --- added by britannica/install.sh ---"
if grep -qF "$MARK" "$CONF"; then
  echo "== dictd.conf already has our stanza, leaving it"
else
  cp -a "$CONF" "$CONF.bak-$(date +%Y%m%d%H%M%S)"
  # the members of 'words' must already be defined, so append AFTER the
  # include of /var/lib/dictd/db.list
  LIST=$(dict -h localhost -D 2>/dev/null | awk 'NR>1 && $1!~/^(words|eb1911)$/ {printf "%s%s",(n++?",":""),$1}')
  [ -n "$LIST" ] || LIST="gcide,wn"
  { echo ""
    echo "$MARK"
    echo "database eb1911 {"
    echo "        data  \"/usr/local/share/dictd/eb1911.dict.dz\""
    echo "        index \"/usr/local/share/dictd/eb1911.index\""
    echo "}"
    echo "database_virtual words {"
    echo "        database_list \"$LIST\""
    echo "        name \"Dictionaries (not encyclopaedias)\""
    echo "}"
  } >> "$CONF"
  echo "== appended to $CONF  (words = $LIST)"
fi
systemctl restart dictd
sleep 1
echo "== active: $(systemctl is-active dictd)"
echo "== databases:"; dict -h localhost -D 2>&1 | sed 's/^/   /'
echo "== 'words' on sublime (should NOT include Britannica):"
dict -h localhost -d words sublime 2>&1 | grep -E "^From|definitions? found" | sed 's/^/   /'
echo "== eb1911 on sublime:"
dict -h localhost -d eb1911 sublime 2>&1 | sed -n '4,6p' | sed 's/^/   /'
