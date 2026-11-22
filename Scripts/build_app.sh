#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP_NAME="Graphe"
APP_BUNDLE="${ROOT_DIR}/build/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

cd "${ROOT_DIR}"

echo "Building ${APP_NAME} (${CONFIG})..."
swift build -c "${CONFIG}" --product "${APP_NAME}" ${EXTRA_SWIFT_FLAGS:-}

BIN_DIR="$(swift build -c "${CONFIG}" ${EXTRA_SWIFT_FLAGS:-} --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

ICON_PATH="${ROOT_DIR}/Resources/AppIcon.icns"
if [ -f "${ICON_PATH}" ]; then
    cp "${ICON_PATH}" "${RESOURCES_DIR}/AppIcon.icns"
fi

BUNDLED_DICTS="${ROOT_DIR}/Resources/BundledDictionaries"
if [ -d "${BUNDLED_DICTS}" ]; then
    cp -R "${BUNDLED_DICTS}" "${RESOURCES_DIR}/BundledDictionaries"
    chmod -R a+rX "${RESOURCES_DIR}/BundledDictionaries"
fi

cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>tr</string>
    <key>CFBundleExecutable</key>
    <string>Graphe</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.graphe.reader</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Graphe</string>
    <key>CFBundleDisplayName</key>
    <string>Graphe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Graphe yalnızca sizin açtığınız PDF belgelerini okumak için bu klasöre erişir.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Graphe yalnızca sizin açtığınız PDF belgelerini okumak için bu klasöre erişir.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Graphe yalnızca sizin açtığınız PDF belgelerini okumak için bu klasöre erişir.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Graphe, Spotify oynatıcısını (oynat/duraklat/sonraki parça) kontrol etmek için izin ister.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>pdf</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>graphebackup</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Graphe Backup Archive</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.graphe.reader.backup</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.zip-archive</string>
                <string>public.data</string>
            </array>
            <key>UTTypeDescription</key>
            <string>Graphe Backup Archive</string>
            <key>UTTypeIdentifier</key>
            <string>com.graphe.reader.backup</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>graphebackup</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# Sign the app bundle so macOS TCC reliably remembers folder permissions across launches.
# If a local signing certificate is provided via GRAPHE_SIGN_IDENTITY, use it; otherwise ad-hoc sign.
SIGN_IDENTITY="${GRAPHE_SIGN_IDENTITY:--}"
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"

echo "App bundle ready at: ${APP_BUNDLE}"
