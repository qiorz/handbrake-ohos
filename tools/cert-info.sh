#!/bin/bash
# Print subject/issuer of every certificate in the signing material, so the
# -issuer argument passed to hap-sign-tool matches the real CA subject DN.
cd "${1:-signing}" || { echo "usage: $0 <signing-dir>"; exit 1; }
for f in root-ca.cer app-ca.cer hb-app-chain.cer profile-debug.pem; do
  [ -f "$f" ] || continue
  echo "================ $f ================"
  awk 'BEGIN{n=0} /-----BEGIN CERTIFICATE-----/{n++; out=sprintf("part-%02d.pem", n)} {if(out) print > out} /-----END CERTIFICATE-----/{close(out); out=""}' "$f"
  for p in part-*.pem; do
    [ -f "$p" ] || continue
    sub=$(openssl x509 -in "$p" -noout -subject 2>/dev/null)
    iss=$(openssl x509 -in "$p" -noout -issuer  2>/dev/null)
    if [ -n "$sub" ]; then
      echo "  SUBJECT: $sub"
      echo "  ISSUER : $iss"
    fi
  done
  rm -f part-*.pem
done
