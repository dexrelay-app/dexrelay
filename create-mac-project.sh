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
