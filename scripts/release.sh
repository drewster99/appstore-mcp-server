#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$REPO_ROOT/appstore/main.swift"
PYPROJECT_FILE="$REPO_ROOT/python/pyproject.toml"
PROJECT="$REPO_ROOT/appstore.xcodeproj"
DERIVED_DATA="$REPO_ROOT/.build/release"
PRODUCT_NAME="appstore"
# Developer ID signing + notarization, so downloaded binaries pass Gatekeeper and keep working after
# the signing certificate expires (an ad-hoc or Apple Development signature is rejected or killed).
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Nuclear Cyborg Corp (P8MA38JTXY)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ncc-cli-notarytool}"

# Track files to clean up on exit (success or failure)
CLEANUP_FILES=()
# Copies of the version files, restored if the release fails before the version bump is committed.
VERSION_BACKUP_DIR=""
VERSION_COMMITTED=0

safe_rmrf() {
    local dir="$1"
    # Refuse to remove empty, root, relative, or parent-traversal paths
    if [[ -z "$dir" || "$dir" == "/" || "$dir" == "." || "$dir" == ".." || "$dir" == ./* || "$dir" == ../* ]]; then
        echo "WARNING: Refusing to rm -rf unsafe path: '$dir'" >&2
        return 1
    fi
    # Must be an absolute path
    if [[ "$dir" != /* ]]; then
        echo "WARNING: Refusing to rm -rf non-absolute path: '$dir'" >&2
        return 1
    fi
    # Must have at least 3 path components (e.g., /a/b/c)
    local slashes="${dir//[^\/]/}"
    if [[ "${#slashes}" -lt 3 ]]; then
        echo "WARNING: Refusing to rm -rf shallow path: '$dir'" >&2
        return 1
    fi
    rm -rf "$dir"
}

cleanup() {
    if [[ -n "$VERSION_BACKUP_DIR" && "$VERSION_COMMITTED" -eq 0 ]]; then
        echo "Release did not complete; restoring version files." >&2
        cp "$VERSION_BACKUP_DIR/main.swift" "$VERSION_FILE"
        cp "$VERSION_BACKUP_DIR/pyproject.toml" "$PYPROJECT_FILE"
    fi
    for f in "${CLEANUP_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
        elif [[ -d "$f" ]]; then
            safe_rmrf "$f" || true
        fi
    done
}

trap cleanup EXIT

# --- Helpers ---

die() { echo "ERROR: $1" >&2; exit 1; }

current_version() {
    sed -n 's/^let appVersion = "\(.*\)"/\1/p' "$VERSION_FILE"
}

bump_patch() {
    local v="$1"
    local major minor patch
    major="${v%%.*}"
    minor="${v#*.}"; minor="${minor%.*}"
    patch="${v##*.}"
    echo "$major.$minor.$((patch + 1))"
}

validate_semver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid semver: $1"
}

# --- Pre-flight checks ---

command -v gh >/dev/null 2>&1 || die "'gh' CLI not found. Install: brew install gh"
gh auth status >/dev/null 2>&1 || die "'gh' not authenticated. Run: gh auth login"
command -v xcodebuild >/dev/null 2>&1 || die "'xcodebuild' not found"
command -v uv >/dev/null 2>&1 || die "'uv' not found. Install: brew install uv"
command -v shasum >/dev/null 2>&1 || die "'shasum' not found"
security find-identity -v -p codesigning | grep -qF "\"$SIGNING_IDENTITY\"" \
    || die "Signing identity not found in the keychain: $SIGNING_IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool keychain profile '$NOTARY_PROFILE' does not work. Create it: xcrun notarytool store-credentials $NOTARY_PROFILE"

# Check for PyPI credentials before starting
if [[ -z "${UV_PUBLISH_TOKEN:-}" ]] && [[ ! -f "$HOME/.pypirc" ]]; then
    echo "Warning: No PyPI credentials found (UV_PUBLISH_TOKEN not set, ~/.pypirc not found)."
    echo "PyPI publish step will likely fail."
    read -r -p "Continue anyway? [y/N]: " PYPI_CRED_CONFIRM
    [[ "$PYPI_CRED_CONFIRM" =~ ^[Yy]$ ]] || die "Aborting. Set UV_PUBLISH_TOKEN or create ~/.pypirc first."
fi

cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
    die "Git working tree is not clean. Commit or stash changes first."
fi

# --- Determine version ---

CURRENT=$(current_version)
[[ -n "$CURRENT" ]] || die "Could not read current version from $VERSION_FILE"

if [[ $# -ge 1 ]]; then
    VERSION="$1"
else
    SUGGESTED=$(bump_patch "$CURRENT")
    read -r -p "Current version: $CURRENT. Next version [$SUGGESTED]: " VERSION
    VERSION="${VERSION:-$SUGGESTED}"
fi

validate_semver "$VERSION"

if git tag -l "v$VERSION" | grep -q .; then
    die "Tag v$VERSION already exists"
fi

echo ""
echo "Releasing v$VERSION (was $CURRENT)"
echo "=================================="
echo ""

# --- Update version in source files ---

VERSION_BACKUP_DIR="$(mktemp -d)"
CLEANUP_FILES+=("$VERSION_BACKUP_DIR")
cp "$VERSION_FILE" "$VERSION_BACKUP_DIR/main.swift"
cp "$PYPROJECT_FILE" "$VERSION_BACKUP_DIR/pyproject.toml"

echo "Updating version in $VERSION_FILE..."
sed -i '' "s|^let appVersion = \".*\"|let appVersion = \"$VERSION\"|" "$VERSION_FILE"

echo "Updating version in $PYPROJECT_FILE..."
sed -i '' "s|^version = \".*\"|version = \"$VERSION\"|" "$PYPROJECT_FILE"

# --- Build ---

echo ""
echo "Building Release binary (arm64)..."
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$PRODUCT_NAME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY=- \
    -quiet

BINARY="$DERIVED_DATA/Build/Products/Release/$PRODUCT_NAME"
[[ -f "$BINARY" ]] || die "Build succeeded but binary not found at $BINARY"

echo "Build complete: $BINARY"

# --- Sign: Developer ID, hardened runtime, secure timestamp ---

echo "Signing binary with $SIGNING_IDENTITY..."
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$BINARY"
codesign --verify --strict --verbose=1 "$BINARY" || die "Signature verification failed"
codesign --display --verbose=2 "$BINARY" 2>&1 | grep -qF "Authority=$SIGNING_IDENTITY" \
    || die "Binary is not signed by $SIGNING_IDENTITY"

# --- Notarize ---

echo "Submitting to Apple for notarization (this can take a few minutes)..."
NOTARY_ZIP="$(mktemp -d)/$PRODUCT_NAME.zip"
CLEANUP_FILES+=("$(dirname "$NOTARY_ZIP")")
ditto -c -k --keepParent "$BINARY" "$NOTARY_ZIP"
NOTARY_JSON="$(dirname "$NOTARY_ZIP")/result.json"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$NOTARY_JSON" \
    || die "notarytool submit failed: $(cat "$NOTARY_JSON")"
# `notarytool submit --wait` exits 0 when the *submission* worked, even if Apple rejected the binary;
# only the reported status says whether it was accepted.
NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_JSON" 2>/dev/null || echo unknown)"
NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_JSON" 2>/dev/null || echo unknown)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "Notarization status: $NOTARY_STATUS (submission $NOTARY_ID). Apple's log:" >&2
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | head -60 >&2
    die "Notarization was not accepted"
fi
echo "Notarized (submission $NOTARY_ID)."
# A bare Mach-O cannot have a ticket stapled; Gatekeeper checks the notarization online on first run.

# --- Archive ---

ARCHIVE_NAME="$PRODUCT_NAME-$VERSION-macos-arm64.tar.gz"
ARCHIVE_PATH="$REPO_ROOT/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

CLEANUP_FILES+=("$ARCHIVE_PATH" "$CHECKSUM_PATH" "$DERIVED_DATA" "$REPO_ROOT/python/README.md")

echo "Creating archive: $ARCHIVE_NAME..."
tar -czf "$ARCHIVE_PATH" -C "$(dirname "$BINARY")" "$PRODUCT_NAME"

echo "Archive created: $(du -h "$ARCHIVE_PATH" | cut -f1) compressed"

# --- Generate SHA256 checksum ---

echo "Generating SHA256 checksum..."
shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}' > "$CHECKSUM_PATH"
echo "Checksum: $(cat "$CHECKSUM_PATH")"

# --- Commit and tag ---

echo ""
echo "Committing version bump..."
git add "$VERSION_FILE" "$PYPROJECT_FILE"
git commit -m "Release v$VERSION"
VERSION_COMMITTED=1
git tag -a "v$VERSION" -m "Release v$VERSION"

# --- Push ---

echo ""
read -r -p "Push commit and tag to origin? [Y/n]: " PUSH_CONFIRM
PUSH_CONFIRM="${PUSH_CONFIRM:-Y}"
if [[ "$PUSH_CONFIRM" =~ ^[Yy]$ ]]; then
    git push origin main
    git push origin "v$VERSION"
else
    echo "Skipped push. Run manually:"
    echo "  git push origin main && git push origin v$VERSION"
    die "Aborting release (tag and commit are local only)"
fi

# --- GitHub Release ---

echo ""
echo "Creating GitHub Release..."
gh release create "v$VERSION" \
    "$ARCHIVE_PATH" \
    "$CHECKSUM_PATH" \
    --title "v$VERSION" \
    --generate-notes

echo "GitHub Release created."

# --- PyPI publish ---

echo ""
read -r -p "Build and publish to PyPI? [Y/n]: " PYPI_CONFIRM
PYPI_CONFIRM="${PYPI_CONFIRM:-Y}"
if [[ "$PYPI_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Building Python package..."
    safe_rmrf "$REPO_ROOT/python/dist"
    # Copy README into python/ so setuptools can access it (it refuses paths outside the package dir)
    cp "$REPO_ROOT/README.md" "$REPO_ROOT/python/README.md"
    cd "$REPO_ROOT/python"
    uv build
    rm -f "$REPO_ROOT/python/README.md"
    echo "Publishing to PyPI..."
    # uv publish doesn't read ~/.pypirc like twine does, so extract the token
    if [[ -n "${UV_PUBLISH_TOKEN:-}" ]]; then
        uv publish --token "$UV_PUBLISH_TOKEN"
    elif [[ -f "$HOME/.pypirc" ]]; then
        PYPI_TOKEN=$(sed -n '/^\[pypi\]/,/^\[/{s/^[[:space:]]*password[[:space:]]*=[[:space:]]*//p;}' "$HOME/.pypirc")
        if [[ -n "$PYPI_TOKEN" ]]; then
            uv publish --token "$PYPI_TOKEN"
        else
            die "No password found in ~/.pypirc [pypi] section"
        fi
    else
        die "No PyPI credentials found. Set UV_PUBLISH_TOKEN or add token to ~/.pypirc"
    fi
    cd "$REPO_ROOT"
    echo "PyPI package published."
else
    echo "Skipped PyPI publish. Run manually:"
    echo "  cd python && cp ../README.md . && uv build && rm README.md && UV_PUBLISH_TOKEN=<token> uv publish"
fi

# --- Cleanup handled by trap ---

echo ""
echo "Release v$VERSION complete!"
echo "  GitHub: https://github.com/drewster99/appstore-mcp-server/releases/tag/v$VERSION"
echo "  PyPI:   https://pypi.org/project/appstore-mcp-server/$VERSION/"
