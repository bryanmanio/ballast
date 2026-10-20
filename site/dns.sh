#!/bin/sh
# DNS for ballast.ing — Netlify serves the site, Fastmail handles the mail.
#
# Every record is DNS-only (proxied false): Cloudflare's proxy would get in the
# way of Netlify provisioning its certificate, and MX and DKIM records cannot
# be proxied at all.
#
#   sh site/dns.sh --dry-run   validate without changing anything
#   sh site/dns.sh             create the records
#
# cf needs Node 22; the PATH line below pins it so this works from any shell.

set -e
export PATH="$HOME/.nvm/versions/node/v22.17.0/bin:$PATH"

Z=ballast.ing
DRY="$1"

rec() {
  echo "→ $(echo "$1" | sed -n 's/.*"type":"\([^"]*\)".*"name":"\([^"]*\)".*/\1 \2/p')"
  cf dns records create -z "$Z" $DRY --body "$1"
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
rec '{"type":"TXT","name":"ballast.ing","content":"\"v=spf1 include:spf.messagingengine.com ?all\"","ttl":1,"comment":"Fastmail SPF"}'

echo
echo "Done. Check with: cf dns records list -z $Z"
