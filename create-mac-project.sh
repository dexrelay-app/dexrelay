#!/bin/zsh
set -euo pipefail

BASE_DIR=""
PROJECT_NAME=""
PROJECT_KIND="folder"
BUNDLE_PREFIX="com.example"
TEAM_ID=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_AUTOMATION_SCRIPT="$SCRIPT_DIR/git-project-automation.sh"
GOVERNANCECTL_SCRIPT="$SCRIPT_DIR/governancectl.py"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-dir)
      BASE_DIR="$2"
      shift 2
      ;;
    --name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --kind)
      PROJECT_KIND="$2"
      shift 2
      ;;
    --bundle-prefix)
      BUNDLE_PREFIX="$2"
      shift 2
      ;;
    --team-id)
      TEAM_ID="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

trimmed_name="$(printf '%s' "$PROJECT_NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
trimmed_base="$(printf '%s' "$BASE_DIR" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

if [[ -z "$trimmed_name" ]]; then
  echo "Project name is required" >&2
  exit 1
fi

if [[ -z "$trimmed_base" ]]; then
  echo "Base directory is required" >&2
  exit 1
fi

safe_token="$(printf '%s' "$trimmed_name" | tr -cd '[:alnum:]')"
if [[ -z "$safe_token" ]]; then
  safe_token="Project$(date +%s)"
fi

bundle_suffix="$(printf '%s' "$trimmed_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"
if [[ -z "$bundle_suffix" ]]; then
  bundle_suffix="app$(date +%s)"
fi
package_slug="$(printf '%s' "$trimmed_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//')"
if [[ -z "$package_slug" ]]; then
  package_slug="web-app-$(date +%s)"
fi

project_root="$trimmed_base/$trimmed_name"
module_dir="$project_root/$safe_token"
project_file="$safe_token.xcodeproj"
project_bundle_id="$BUNDLE_PREFIX.$bundle_suffix"
app_struct_name="${safe_token}App"
development_team_settings=""
project_sdkroot="iphoneos"
project_supported_platforms="iphoneos iphonesimulator"
project_deployment_key="IPHONEOS_DEPLOYMENT_TARGET"
project_deployment_target="17.0"
targeted_device_family_setting='				TARGETED_DEVICE_FAMILY = "1,2";'
indirect_input_setting='				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;'

if [[ -n "$TEAM_ID" ]]; then
  development_team_settings=$'				DEVELOPMENT_TEAM = '"$TEAM_ID"$';\n'
fi

if [[ -e "$project_root" ]]; then
  echo "Project already exists at $project_root" >&2
  exit 1
fi

mkdir -p "$project_root"

if [[ "$PROJECT_KIND" == "folder" ]]; then
  cat > "$project_root/README.md" <<TXT
# $trimmed_name

Created from Codex iPhone to Mac Relay.
TXT
  if [[ -f "$GOVERNANCECTL_SCRIPT" ]]; then
    python3 "$GOVERNANCECTL_SCRIPT" update-project --project-path "$project_root" --project-name "$trimmed_name" >/dev/null
  fi
  git_info="$("$GIT_AUTOMATION_SCRIPT" --mode ensure --cwd "$project_root")"
  python3 - <<PY "$project_root" "$PROJECT_KIND" "$git_info"
import json, sys
git_info = json.loads(sys.argv[3])
print(json.dumps({
  "projectPath": sys.argv[1],
  "kind": sys.argv[2],
  "projectFile": None,
  "scheme": None,
  "gitRoot": git_info.get("gitRoot"),
  "gitBranch": git_info.get("branch"),
}))
PY
  exit 0
fi

if [[ "$PROJECT_KIND" == "web-app" ]]; then
  mkdir -p "$project_root/src"
  mkdir -p "$project_root/public"

  cat > "$project_root/package.json" <<JSON
{
  "name": "$package_slug",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite --host 0.0.0.0",
    "build": "tsc -b && vite build",
    "preview": "vite preview --host 0.0.0.0",
    "lint": "eslint .",
    "typecheck": "tsc -b --pretty"
  },
  "dependencies": {
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  },
  "devDependencies": {
    "@eslint/js": "^9.0.0",
    "@vitejs/plugin-react": "^4.3.0",
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "eslint": "^9.0.0",
    "eslint-plugin-react-hooks": "^5.2.0",
    "eslint-plugin-react-refresh": "^0.4.20",
    "globals": "^16.0.0",
    "typescript": "^5.8.0",
    "typescript-eslint": "^8.0.0",
    "vite": "^6.0.0"
  }
}
JSON

  cat > "$project_root/index.html" <<HTML
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta
      name="description"
      content="$trimmed_name is a Vite React TypeScript app scaffolded by DexRelay."
    />
    <title>$trimmed_name</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
HTML

  cat > "$project_root/vite.config.ts" <<'TS'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
})
TS

  cat > "$project_root/tsconfig.json" <<'JSON'
{
  "files": [],
  "references": [
    { "path": "./tsconfig.app.json" },
    { "path": "./tsconfig.node.json" }
  ]
}
JSON

  cat > "$project_root/tsconfig.app.json" <<'JSON'
{
  "compilerOptions": {
    "tsBuildInfoFile": "./node_modules/.tmp/tsconfig.app.tsbuildinfo",
    "target": "ES2022",
    "useDefineForClassFields": true,
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "allowJs": false,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "allowSyntheticDefaultImports": true,
    "strict": true,
    "forceConsistentCasingInFileNames": true,
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx"
  },
  "include": ["src"]
}
JSON

  cat > "$project_root/tsconfig.node.json" <<'JSON'
{
  "compilerOptions": {
    "tsBuildInfoFile": "./node_modules/.tmp/tsconfig.node.tsbuildinfo",
    "target": "ES2023",
    "lib": ["ES2023"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "Bundler",
    "allowImportingTsExtensions": true,
    "isolatedModules": true,
    "moduleDetection": "force",
    "noEmit": true,
    "strict": true
  },
  "include": ["vite.config.ts"]
}
JSON

  cat > "$project_root/eslint.config.js" <<'JS'
import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'

export default tseslint.config(
  { ignores: ['dist'] },
  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      ecmaVersion: 2022,
      globals: globals.browser,
    },
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': [
        'warn',
        { allowConstantExport: true },
      ],
    },
  },
)
JS

  cat > "$project_root/src/main.tsx" <<'TSX'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './styles.css'

const root = document.getElementById('root')

if (!root) {
  throw new Error('Root element #root was not found')
}

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
TSX

  cat > "$project_root/src/App.tsx" <<TSX
const metrics = [
  { label: 'Build system', value: 'Vite' },
  { label: 'Language', value: 'TypeScript' },
  { label: 'UI runtime', value: 'React' },
]

const principles = [
  'Typed from the first component',
  'Responsive layout without a CSS framework dependency',
  'Accessible landmarks, focus states, and contrast',
]

function App() {
  return (
    <main className="app-shell">
      <section className="hero" aria-labelledby="page-title">
        <div className="hero__copy">
          <p className="eyebrow">DexRelay web starter</p>
          <h1 id="page-title">$trimmed_name</h1>
          <p className="lede">
            A production-ready React + TypeScript starter with a clean Vite
            toolchain, strict compiler settings, and responsive design tokens.
          </p>
          <div className="hero__actions" aria-label="Primary actions">
            <a className="button button--primary" href="#getting-started">
              Start building
            </a>
            <a className="button button--secondary" href="https://vite.dev" target="_blank" rel="noreferrer">
              Vite docs
            </a>
          </div>
        </div>

        <div className="status-card" aria-label="Project stack">
          {metrics.map((item) => (
            <div className="metric" key={item.label}>
              <span>{item.label}</span>
              <strong>{item.value}</strong>
            </div>
          ))}
        </div>
      </section>

      <section className="panel" id="getting-started" aria-labelledby="getting-started-title">
        <div>
          <p className="eyebrow">Getting started</p>
          <h2 id="getting-started-title">Ship the first useful screen, then iterate.</h2>
        </div>
        <ol className="steps">
          <li>
            <code>npm install</code>
            <span>Install dependencies.</span>
          </li>
          <li>
            <code>npm run dev</code>
            <span>Start the local development server.</span>
          </li>
          <li>
            <code>npm run build</code>
            <span>Typecheck and produce a production build.</span>
          </li>
        </ol>
      </section>

      <section className="principles" aria-label="Starter principles">
        {principles.map((principle) => (
          <article key={principle}>
            <span aria-hidden="true">◆</span>
            <p>{principle}</p>
          </article>
        ))}
      </section>
    </main>
  )
}

export default App
TSX

  cat > "$project_root/src/styles.css" <<'CSS'
:root {
  color-scheme: light;
  font-family:
    ui-sans-serif,
    "Avenir Next",
    "Helvetica Neue",
    system-ui,
    sans-serif;
  background: #f7f3ea;
  color: #151512;
  font-synthesis: none;
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;

  --ink: #151512;
  --muted: #676258;
  --paper: #fffaf0;
  --paper-strong: #ffffff;
  --line: #dfd5c2;
  --accent: #c8a938;
  --accent-ink: #211b07;
  --shadow: 0 24px 80px rgb(55 43 18 / 14%);
}

* {
  box-sizing: border-box;
}

html {
  scroll-behavior: smooth;
}

body {
  margin: 0;
  min-width: 320px;
  min-height: 100vh;
  background:
    radial-gradient(circle at top left, rgb(200 169 56 / 18%), transparent 34rem),
    linear-gradient(135deg, #f7f3ea 0%, #eee7d7 100%);
}

a {
  color: inherit;
}

a:focus-visible,
button:focus-visible {
  outline: 3px solid rgb(200 169 56 / 70%);
  outline-offset: 3px;
}

.app-shell {
  width: min(1120px, calc(100% - 32px));
  margin: 0 auto;
  padding: 56px 0;
}

.hero {
  display: grid;
  grid-template-columns: minmax(0, 1.3fr) minmax(280px, 0.7fr);
  gap: 28px;
  align-items: stretch;
}

.hero__copy,
.status-card,
.panel,
.principles article {
  border: 1px solid var(--line);
  background: rgb(255 250 240 / 82%);
  box-shadow: var(--shadow);
  backdrop-filter: blur(18px);
}

.hero__copy {
  min-height: 520px;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  padding: clamp(28px, 5vw, 64px);
  border-radius: 36px;
}

.eyebrow {
  margin: 0 0 14px;
  color: var(--accent);
  font-size: 0.78rem;
  font-weight: 800;
  letter-spacing: 0.14em;
  text-transform: uppercase;
}

h1,
h2,
p {
  margin-top: 0;
}

h1 {
  max-width: 11ch;
  margin-bottom: 22px;
  font-size: clamp(3.25rem, 12vw, 8rem);
  line-height: 0.88;
  letter-spacing: -0.08em;
}

h2 {
  max-width: 14ch;
  margin-bottom: 0;
  font-size: clamp(2rem, 5vw, 4rem);
  line-height: 0.95;
  letter-spacing: -0.06em;
}

.lede {
  max-width: 58ch;
  color: var(--muted);
  font-size: clamp(1.05rem, 2vw, 1.25rem);
  line-height: 1.65;
}

.hero__actions {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin-top: 18px;
}

.button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 48px;
  padding: 0 18px;
  border-radius: 999px;
  font-weight: 800;
  text-decoration: none;
  transition:
    transform 180ms ease,
    box-shadow 180ms ease,
    background 180ms ease;
}

.button:hover {
  transform: translateY(-2px);
}

.button--primary {
  background: var(--ink);
  color: var(--paper);
  box-shadow: 0 12px 30px rgb(21 21 18 / 18%);
}

.button--secondary {
  border: 1px solid var(--line);
  background: var(--paper-strong);
}

.status-card {
  display: grid;
  align-content: end;
  gap: 16px;
  padding: 28px;
  border-radius: 36px;
}

.metric {
  display: grid;
  gap: 8px;
  padding: 18px;
  border-radius: 24px;
  background: rgb(255 255 255 / 60%);
}

.metric span {
  color: var(--muted);
  font-size: 0.78rem;
  font-weight: 800;
  letter-spacing: 0.1em;
  text-transform: uppercase;
}

.metric strong {
  font-size: clamp(1.5rem, 3vw, 2.5rem);
  letter-spacing: -0.05em;
}

.panel {
  display: grid;
  grid-template-columns: minmax(0, 0.9fr) minmax(280px, 1.1fr);
  gap: 28px;
  margin-top: 28px;
  padding: clamp(24px, 5vw, 44px);
  border-radius: 32px;
}

.steps {
  display: grid;
  gap: 12px;
  margin: 0;
  padding: 0;
  list-style: none;
}

.steps li {
  display: grid;
  grid-template-columns: minmax(128px, 0.8fr) minmax(0, 1fr);
  gap: 14px;
  align-items: center;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: 18px;
  background: rgb(255 255 255 / 58%);
}

code {
  color: var(--accent-ink);
  font-family: "SFMono-Regular", ui-monospace, monospace;
  font-weight: 800;
}

.steps span,
.principles p {
  margin: 0;
  color: var(--muted);
  line-height: 1.5;
}

.principles {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 16px;
  margin-top: 16px;
}

.principles article {
  min-height: 150px;
  padding: 22px;
  border-radius: 26px;
}

.principles span {
  display: inline-block;
  margin-bottom: 28px;
  color: var(--accent);
}

@media (max-width: 760px) {
  .app-shell {
    width: min(100% - 24px, 560px);
    padding: 28px 0;
  }

  .hero,
  .panel,
  .principles {
    grid-template-columns: 1fr;
  }

  .hero__copy {
    min-height: 440px;
    border-radius: 28px;
  }

  .status-card,
  .panel {
    border-radius: 28px;
  }

  .steps li {
    grid-template-columns: 1fr;
  }
}
CSS

  cat > "$project_root/src/vite-env.d.ts" <<'TS'
/// <reference types="vite/client" />
TS

  cat > "$project_root/.gitignore" <<'TXT'
node_modules
dist
.DS_Store
.env
.env.local
npm-debug.log*
yarn-debug.log*
yarn-error.log*
pnpm-debug.log*
TXT

  cat > "$project_root/README.md" <<TXT
# $trimmed_name

Created from DexRelay as a Vite React TypeScript web app.

## Commands

\`\`\`bash
npm install
npm run dev
npm run build
npm run lint
\`\`\`

## Project shape

- \`src/App.tsx\` contains the starter product surface.
- \`src/styles.css\` defines responsive design tokens and layout.
- \`npm run build\` runs TypeScript project references before Vite builds.
- \`npm run dev\` binds to \`0.0.0.0\` so DexRelay can expose the local dev server when needed.
TXT

  if [[ -f "$GOVERNANCECTL_SCRIPT" ]]; then
    python3 "$GOVERNANCECTL_SCRIPT" update-project --project-path "$project_root" --project-name "$trimmed_name" >/dev/null
  fi
  git_info="$("$GIT_AUTOMATION_SCRIPT" --mode ensure --cwd "$project_root")"
  python3 - <<PY "$project_root" "$PROJECT_KIND" "$git_info"
import json, sys
git_info = json.loads(sys.argv[3])
print(json.dumps({
  "projectPath": sys.argv[1],
  "kind": sys.argv[2],
  "projectFile": None,
  "scheme": "npm run dev",
  "gitRoot": git_info.get("gitRoot"),
  "gitBranch": git_info.get("branch"),
}))
PY
  exit 0
fi

if [[ "$PROJECT_KIND" == "mac-app" ]]; then
  project_sdkroot="macosx"
  project_supported_platforms="macosx"
  project_deployment_key="MACOSX_DEPLOYMENT_TARGET"
  project_deployment_target="14.0"
  targeted_device_family_setting=""
  indirect_input_setting=""
fi

if [[ "$PROJECT_KIND" != "ios-app" && "$PROJECT_KIND" != "mac-app" ]]; then
  echo "Unsupported kind: $PROJECT_KIND" >&2
  exit 1
fi

mkdir -p "$module_dir/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$project_root/$project_file"

cat > "$module_dir/AppMain.swift" <<SWIFT
import SwiftUI

@main
struct $app_struct_name: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
SWIFT

cat > "$module_dir/ContentView.swift" <<SWIFT
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("$trimmed_name")
                    .font(.largeTitle.weight(.bold))

                Text("Bootstrapped from Codex iPhone to Mac Relay.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .navigationTitle("$trimmed_name")
        }
    }
}

#Preview {
    ContentView()
}
SWIFT

if [[ "$PROJECT_KIND" == "mac-app" ]]; then
cat > "$module_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>\$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleExecutable</key>
    <string>\$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>\$(PRODUCT_NAME)</string>
    <key>CFBundleDisplayName</key>
    <string>$trimmed_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST
else
cat > "$module_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>\$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleExecutable</key>
    <string>\$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>\$(PRODUCT_NAME)</string>
    <key>CFBundleDisplayName</key>
    <string>$trimmed_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <false/>
    </dict>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
</dict>
</plist>
PLIST
fi

cat > "$module_dir/Assets.xcassets/Contents.json" <<JSON
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

if [[ "$PROJECT_KIND" == "mac-app" ]]; then
cat > "$module_dir/Assets.xcassets/AppIcon.appiconset/Contents.json" <<JSON
{
  "images" : [
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
else
cat > "$module_dir/Assets.xcassets/AppIcon.appiconset/Contents.json" <<JSON
{
  "images" : [
    {
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "20x20"
    },
    {
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "20x20"
    },
    {
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "29x29"
    },
    {
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "29x29"
    },
    {
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "40x40"
    },
    {
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "40x40"
    },
    {
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "60x60"
    },
    {
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "60x60"
    },
    {
      "idiom" : "ios-marketing",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
fi

cat > "$project_root/$project_file/project.pbxproj" <<PBX
// !\$*UTF8*\$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		A1B2C3D41A00000100000001 /* AppMain.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1B2C3D31A00000100000001 /* AppMain.swift */; };
		A1B2C3D41A00000100000002 /* ContentView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1B2C3D31A00000100000002 /* ContentView.swift */; };
		A1B2C3D41A00000100000005 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = A1B2C3D31A00000100000005 /* Assets.xcassets */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		A1B2C3D31A00000100000001 /* AppMain.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppMain.swift; sourceTree = "<group>"; };
		A1B2C3D31A00000100000002 /* ContentView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ContentView.swift; sourceTree = "<group>"; };
		A1B2C3D31A00000100000005 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
		A1B2C3D31A00000100000006 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		A1B2C3D31A00000100000007 /* $safe_token.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "$safe_token.app"; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		A1B2C3D51A00000100000001 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		A1B2C3D21A00000100000001 = {
			isa = PBXGroup;
			children = (
				A1B2C3D21A00000100000002 /* $safe_token */,
				A1B2C3D21A00000100000003 /* Products */,
			);
			sourceTree = "<group>";
		};
		A1B2C3D21A00000100000002 /* $safe_token */ = {
			isa = PBXGroup;
			children = (
				A1B2C3D31A00000100000001 /* AppMain.swift */,
				A1B2C3D31A00000100000002 /* ContentView.swift */,
				A1B2C3D31A00000100000005 /* Assets.xcassets */,
				A1B2C3D31A00000100000006 /* Info.plist */,
			);
			path = "$safe_token";
			sourceTree = "<group>";
		};
		A1B2C3D21A00000100000003 /* Products */ = {
			isa = PBXGroup;
			children = (
				A1B2C3D31A00000100000007 /* $safe_token.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		A1B2C3D61A00000100000001 /* $safe_token */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A1B2C3D71A00000100000001 /* Build configuration list for PBXNativeTarget "$safe_token" */;
			buildPhases = (
				A1B2C3D51A00000100000002 /* Sources */,
				A1B2C3D51A00000100000001 /* Frameworks */,
				A1B2C3D51A00000100000003 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = "$safe_token";
			productName = "$safe_token";
			productReference = A1B2C3D31A00000100000007 /* $safe_token.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		A1B2C3D11A00000100000001 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {
					A1B2C3D61A00000100000001 = {
						CreatedOnToolsVersion = 16.0;
					};
				};
			};
			buildConfigurationList = A1B2C3D71A00000100000002 /* Build configuration list for PBXProject "$safe_token" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = A1B2C3D21A00000100000001;
			productRefGroup = A1B2C3D21A00000100000003 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				A1B2C3D61A00000100000001 /* $safe_token */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		A1B2C3D51A00000100000003 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A1B2C3D41A00000100000005 /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		A1B2C3D51A00000100000002 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A1B2C3D41A00000100000001 /* AppMain.swift in Sources */,
				A1B2C3D41A00000100000002 /* ContentView.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		A1B2C3D81A00000100000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"\$(inherited)",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				${project_deployment_key} = ${project_deployment_target};
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = ${project_sdkroot};
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		A1B2C3D81A00000100000002 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				${project_deployment_key} = ${project_deployment_target};
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SDKROOT = ${project_sdkroot};
				SWIFT_COMPILATION_MODE = wholemodule;
				VALIDATE_PRODUCT = YES;
			};
			name = Release;
		};
		A1B2C3D81A00000100000003 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
${development_team_settings}				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "$safe_token/Info.plist";
${indirect_input_setting}
				LD_RUNPATH_SEARCH_PATHS = (
					"\$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = $project_bundle_id;
				PRODUCT_NAME = "\$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "$project_supported_platforms";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
${targeted_device_family_setting}
			};
			name = Debug;
		};
		A1B2C3D81A00000100000004 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
${development_team_settings}				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "$safe_token/Info.plist";
${indirect_input_setting}
				LD_RUNPATH_SEARCH_PATHS = (
					"\$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = $project_bundle_id;
				PRODUCT_NAME = "\$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "$project_supported_platforms";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
${targeted_device_family_setting}
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		A1B2C3D71A00000100000001 /* Build configuration list for PBXNativeTarget "$safe_token" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A1B2C3D81A00000100000003 /* Debug */,
				A1B2C3D81A00000100000004 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		A1B2C3D71A00000100000002 /* Build configuration list for PBXProject "$safe_token" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A1B2C3D81A00000100000001 /* Debug */,
				A1B2C3D81A00000100000002 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = A1B2C3D11A00000100000001 /* Project object */;
}
PBX

cat > "$project_root/README.md" <<TXT
# $trimmed_name

Created from Codex iPhone to Mac Relay.

Project path: $project_root
Xcode project: $project_file
Scheme: $safe_token
Bundle ID: $project_bundle_id
TXT

git_info="$("$GIT_AUTOMATION_SCRIPT" --mode ensure --cwd "$project_root")"
if [[ -f "$GOVERNANCECTL_SCRIPT" ]]; then
  python3 "$GOVERNANCECTL_SCRIPT" update-project --project-path "$project_root" --project-name "$trimmed_name" >/dev/null
fi

python3 - <<PY "$project_root" "$PROJECT_KIND" "$project_file" "$safe_token" "$git_info"
import json, sys
git_info = json.loads(sys.argv[5])
print(json.dumps({
    "projectPath": sys.argv[1],
    "kind": sys.argv[2],
    "projectFile": sys.argv[3],
    "scheme": sys.argv[4],
    "gitRoot": git_info.get("gitRoot"),
    "gitBranch": git_info.get("branch"),
}))
PY
