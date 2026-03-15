#!/usr/bin/env bash
# =============================================================================
# setup-iam.sh — Einmalig lokal ausführen, bevor die GitHub Action funktioniert.
#
# Verwendung:
#   ./scripts/setup-iam.sh [--profile <aws-profile>]
#
# Beispiel mit explizitem Profil:
#   ./scripts/setup-iam.sh --profile david
#
# Voraussetzungen:
#   - AWS CLI konfiguriert mit einem User/Rolle, die IAM- und Route53-Rechte hat
#   - Das GitHub-Repo existiert bereits (Gontrum/palette)
#
# Was dieses Skript tut:
#   1. Liest die AWS Account-ID und die Hosted Zone-ID für gontrum.io aus
#   2. Erstellt eine IAM-Rolle, der das palette-Repo via GitHub OIDC vertrauen darf
#   3. Hängt eine Policy an, die nur Route53-Änderungen an dieser Zone erlaubt
#   4. Gibt die Rolle ARN und die Hosted Zone-ID aus → als GitHub Actions Variables setzen
# =============================================================================

set -euo pipefail

GITHUB_REPO="Gontrum/palette.gontrum.io"
ROLE_NAME="palette-gontrum-io-dns"
DOMAIN="gontrum.io"

# Optionales --profile Argument
AWS_PROFILE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile|-p) AWS_PROFILE_ARG="--profile $2"; shift 2 ;;
    *) echo "Unbekanntes Argument: $1"; exit 1 ;;
  esac
done

# Wrapper, damit --profile nicht bei jedem Aufruf wiederholt werden muss
aws() { command aws $AWS_PROFILE_ARG "$@"; }

echo "→ AWS Account-ID ermitteln..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  Account: $ACCOUNT_ID"

echo "→ Hosted Zone-ID für $DOMAIN ermitteln..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$DOMAIN." \
  --query "HostedZones[0].Id" \
  --output text | sed 's|/hostedzone/||')
echo "  Hosted Zone: $HOSTED_ZONE_ID"

OIDC_PROVIDER="token.actions.githubusercontent.com"

echo "→ IAM-Rolle '$ROLE_NAME' anlegen oder aktualisieren..."
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "${OIDC_PROVIDER}:sub": "repo:${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
  echo "  Rolle existiert bereits — Trust Policy aktualisieren..."
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Allows palette GitHub Actions to upsert palette.gontrum.io CNAME" \
    > /dev/null
fi

echo "→ Route53-Policy anhängen..."
POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/${HOSTED_ZONE_ID}"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "route53-palette-cname" \
  --policy-document "$POLICY"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo ""
echo "✓ Fertig! Setze diese GitHub Actions Variables im palette-Repo:"
echo ""
echo "  AWS_DNS_ROLE_ARN  = $ROLE_ARN"
echo "  HOSTED_ZONE_ID    = $HOSTED_ZONE_ID"
echo ""
echo "  → https://github.com/${GITHUB_REPO}/settings/variables/actions"
