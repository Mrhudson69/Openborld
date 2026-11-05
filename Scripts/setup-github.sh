#!/bin/bash
# Configures the GitHub repository: description, topics, features, and branch
# protection on main.
#
# Run once, after you have push access:
#     bash Scripts/setup-github.sh [owner/repo]
#
# Requires the `gh` CLI authenticated as an account with ADMIN rights on the
# repo. Read or write alone is not enough to change settings or protection.
set -euo pipefail

REPO="${1:-Mrhudson69/Openborld}"

echo "▸ Target: $REPO"
PERM=$(gh repo view "$REPO" --json viewerPermission --jq .viewerPermission)
echo "  your permission: $PERM"
if [ "$PERM" != "ADMIN" ]; then
  echo "✗ Need ADMIN to change settings. Currently: $PERM"
  echo "  Authenticate as the repo owner:  gh auth login"
  exit 1
fi

echo "▸ Description and topics…"
gh repo edit "$REPO" \
  --description "Free, open-source cloud storage manager for macOS — browse and transfer files across Amazon S3, Azure Blob Storage, Backblaze B2, Google Cloud Storage, MinIO, Wasabi, R2, WebDAV and Nextcloud from one dual-pane window." \
  --homepage "https://github.com/${REPO}#readme" \
  --enable-issues \
  --enable-discussions \
  --enable-wiki=false \
  --enable-projects=false \
  --delete-branch-on-merge \
  --enable-squash-merge \
  --enable-merge-commit=false \
  --enable-rebase-merge=false

# Topics are the main way people find a repo through GitHub search, so these
# are the terms someone would actually type.
gh repo edit "$REPO" \
  --add-topic macos \
  --add-topic swift \
  --add-topic swiftui \
  --add-topic s3 \
  --add-topic s3-client \
  --add-topic azure-blob-storage \
  --add-topic cloud-storage \
  --add-topic file-manager \
  --add-topic webdav \
  --add-topic minio \
  --add-topic backblaze-b2 \
  --add-topic nextcloud \
  --add-topic object-storage \
  --add-topic open-source \
  --add-topic macos-app \
  --add-topic file-transfer \
  --add-topic cloudflare-r2 \
  --add-topic wasabi \
  --add-topic cross-platform \
  --add-topic developer-tools

echo "▸ Branch protection on main…"
# Rationale for each rule:
#   - PR required: nothing reaches main unreviewed, including from the owner.
#   - CI must pass: both jobs build and run all 56 tests. Linux is required
#     too, because the portable core is verified there and a regression
#     should fail the PR rather than surface months later.
#   - Conversation resolution: review comments can't be silently ignored.
#   - No force pushes or deletion: history on main stays auditable.
gh api -X PUT "repos/$REPO/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON' >/dev/null
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["macOS — build, test, package", "Linux — portable core"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "require_last_push_approval": false
  },
  "required_conversation_resolution": true,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "restrictions": null
}
JSON

echo "✓ Done."
echo ""
echo "Notes:"
echo "  • required_approving_review_count is 0 so you can merge your own PRs"
echo "    while you are the only maintainer. Raise it to 1 once someone else"
echo "    joins — that is the single most valuable change later."
echo "  • enforce_admins is false, so you can still push a hotfix directly."
echo "    Set it true if you want the rules to bind you too."
echo "  • Both CI jobs are required. Linux runs the same 56 tests as macOS."
