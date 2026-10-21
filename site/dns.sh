#!/bin/sh
# DNS for ballast.ing — Netlify serves the site, Fastmail handles the mail.
#
# Every record is DNS-only (proxied false): Cloudflare's proxy would get in the
# way of Netlify provisioning its certificate, and MX and DKIM records cannot
# be proxied at all.
#
#   sh site/dns.sh --dry-run   report what is missing, change nothing
#   sh site/dns.sh             create whatever is missing
#
# Safe to re-run: the zone is read first and anything already there is skipped.
# This cannot lean on the API to dedupe — Cloudflare rejects a duplicate MX but
# will happily add a second identical TXT, and two SPF records is a permerror.
#
# cf needs Node 22; the PATH line below pins it so this works from any shell.

set -e
export PATH="$HOME/.nvm/versions/node/v22.17.0/bin:$PATH"

Z=ballast.ing
DRY="$1"

EXISTING=$(mktemp)
trap 'rm -f "$EXISTING"' EXIT
cf dns records list -z "$Z" --per-page 500 > "$EXISTING"

# Is this record already in the zone? Compares type, name and content, with the
# zone suffix added to short names and the quotes Cloudflare wraps TXT values in
# stripped, so both sides are spelled the same way.
present() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
want = json.load(sys.stdin)
have = json.load(open(sys.argv[1]))
zone = sys.argv[2]

def norm(rec):
    name = rec["name"]
    if not name.endswith(zone):
        name = name + "." + zone
    return (rec["type"], name.lower(), rec["content"].strip().strip(chr(34)).lower())

sys.exit(0 if norm(want) in {norm(r) for r in have} else 1)
' "$EXISTING" "$Z"
}

rec() {
  label=$(printf '%s' "$1" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(r["type"], r["name"])')
  if present "$1"; then
    echo "= $label already present"
  elif [ -n "$DRY" ]; then
    echo "+ $label would be created"
  else
    cf dns records create -z "$Z" --body "$1" > /dev/null
    echo "+ $label created"
  fi
}

# --- Netlify --------------------------------------------------------------
# Cloudflare flattens an apex CNAME, which is what Netlify asks for at the root.
rec '{"type":"CNAME","name":"ballast.ing","content":"apex-loadbalancer.netlify.com","proxied":false,"ttl":1,"comment":"Netlify apex"}'
rec '{"type":"CNAME","name":"www","content":"ballast-ing.netlify.app","proxied":false,"ttl":1,"comment":"Netlify www"}'

# --- Fastmail -------------------------------------------------------------
rec '{"type":"MX","name":"ballast.ing","content":"us1-smtp.messagingengine.com","priority":10,"ttl":1,"comment":"Fastmail"}'
rec '{"type":"MX","name":"ballast.ing","content":"us2-smtp.messagingengine.com","priority":20,"ttl":1,"comment":"Fastmail"}'
rec '{"type":"CNAME","name":"fm1._domainkey","content":"fm1.ballast.ing.dkim.fmhosted.com","proxied":false,"ttl":1,"comment":"Fastmail DKIM"}'
rec '{"type":"CNAME","name":"fm2._domainkey","content":"fm2.ballast.ing.dkim.fmhosted.com","proxied":false,"ttl":1,"comment":"Fastmail DKIM"}'
rec '{"type":"CNAME","name":"fm3._domainkey","content":"fm3.ballast.ing.dkim.fmhosted.com","proxied":false,"ttl":1,"comment":"Fastmail DKIM"}'
rec '{"type":"TXT","name":"ballast.ing","content":"v=spf1 include:spf.messagingengine.com ?all","ttl":1,"comment":"Fastmail SPF"}'

echo
echo "Done. Check with: cf dns records list -z $Z"
