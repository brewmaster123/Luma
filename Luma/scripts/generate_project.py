#!/usr/bin/env python3
"""Generate a dependency-free, two-target native Xcode project and its app icons."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def obj(key, isa, **values):
    uid = ident(key)
    objects[uid] = {"isa": isa, **values}
    return uid

def dump(value, indent=0):
    pad = "\t" * indent
    if isinstance(value, dict):
        return "{\n" + "".join(pad + "\t" + str(k) + " = " + dump(v, indent + 1) + ";\n" for k, v in value.items()) + pad + "}"
    if isinstance(value, list):
        return "(\n" + "".join(pad + "\t" + dump(v, indent + 1) + ",\n" for v in value) + pad + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)

refs = {}
groups = []
for folder, title in [("Sources/LumaCore", "Core"), ("Sources/Platform", "Services"),
                      ("Sources/iPhone", "iPhone"), ("Sources/Watch", "Apple Watch")]:
    children = []
    for file in sorted((ROOT / folder).glob("*.swift")):
        relative = file.relative_to(ROOT).as_posix()
        ref = obj(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=file.name, sourceTree="<group>")
        refs[relative] = ref; children.append(ref)
    groups.append(obj(folder, "PBXGroup", children=children, name=title, path=folder, sourceTree="<group>"))

resource_children = []
for filename, kind in [("iOSAssets.xcassets", "folder.assetcatalog"),
                       ("WatchAssets.xcassets", "folder.assetcatalog"),
                       ("PrivacyInfo.xcprivacy", "text.xml")] + [(f"Manrope-{style}.ttf", "file") for style in ["Regular", "Medium", "SemiBold"]] + [(f"luma-tone-{n}.wav", "audio.wav") for n in [4,8,15]]:
    path = "Resources/" + filename
    refs[path] = obj(path, "PBXFileReference", lastKnownFileType=kind, path=filename, sourceTree="<group>")
    resource_children.append(refs[path])
groups.append(obj("Resources", "PBXGroup", children=resource_children, path="Resources", sourceTree="<group>"))
config_children = []
for filename in ["Base.xcconfig", "iOS-Info.plist", "Watch-Info.plist", "iOS.entitlements", "Watch.entitlements"]:
    path = "Config/" + filename
    refs[path] = obj(path, "PBXFileReference", lastKnownFileType="text.xcconfig" if filename.endswith("xcconfig") else "text.plist.xml", path=filename, sourceTree="<group>")
    config_children.append(refs[path])
groups.append(obj("Config", "PBXGroup", children=config_children, path="Config", sourceTree="<group>"))

phone_product = obj("product.phone", "PBXFileReference", explicitFileType="wrapper.application", path="Luma.app", sourceTree="BUILT_PRODUCTS_DIR", includeInIndex=0)
watch_product = obj("product.watch", "PBXFileReference", explicitFileType="wrapper.application", path="Luma Watch.app", sourceTree="BUILT_PRODUCTS_DIR", includeInIndex=0)
product_group = obj("products", "PBXGroup", name="Products", children=[phone_product, watch_product], sourceTree="<group>")
main_group = obj("main", "PBXGroup", children=groups + [product_group], sourceTree="<group>")

def configurations(key, settings, base=False):
    configs = []
    for name in ["Debug", "Release"]:
        build = dict(settings)
        build.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if name == "Debug" else "-O",
                     SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) DEBUG" if name == "Debug" else "$(inherited)",
                     DEBUG_INFORMATION_FORMAT="dwarf" if name == "Debug" else "dwarf-with-dsym")
        extras = {"baseConfigurationReference": refs["Config/Base.xcconfig"]} if base else {}
        configs.append(obj(key + name, "XCBuildConfiguration", name=name, buildSettings=build, **extras))
    return obj(key + "List", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

project_configs = configurations("project.config", {"CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "minimal"}, base=True)
phone_configs = configurations("phone.config", {
    "PRODUCT_NAME": "Luma", "PRODUCT_BUNDLE_IDENTIFIER": "$(LUMA_BUNDLE_PREFIX)",
    "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "TARGETED_DEVICE_FAMILY": "1",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "INFOPLIST_FILE": "Config/iOS-Info.plist",
    "CODE_SIGN_ENTITLEMENTS": "Config/iOS.entitlements", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "GENERATE_INFOPLIST_FILE": "NO", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "ENABLE_PREVIEWS": "YES"
})
watch_configs = configurations("watch.config", {
    "PRODUCT_NAME": "Luma Watch", "PRODUCT_BUNDLE_IDENTIFIER": "$(LUMA_BUNDLE_PREFIX).watchkitapp",
    "SDKROOT": "watchos", "SUPPORTED_PLATFORMS": "watchos watchsimulator", "TARGETED_DEVICE_FAMILY": "4",
    "WATCHOS_DEPLOYMENT_TARGET": "10.0", "INFOPLIST_FILE": "Config/Watch-Info.plist",
    "CODE_SIGN_ENTITLEMENTS": "Config/Watch.entitlements", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "GENERATE_INFOPLIST_FILE": "NO", "SKIP_INSTALL": "YES", "ENABLE_PREVIEWS": "YES",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks"
})

def sources_phase(key, prefixes):
    files = [obj(key + path, "PBXBuildFile", fileRef=ref) for path, ref in refs.items() if path.endswith(".swift") and any(path.startswith(p) for p in prefixes)]
    return obj(key, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)

def resources_phase(key, paths):
    files = [obj(key + path, "PBXBuildFile", fileRef=refs[path]) for path in paths]
    return obj(key, "PBXResourcesBuildPhase", buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)

phone_sources = sources_phase("phone.sources", ["Sources/LumaCore/", "Sources/Platform/", "Sources/iPhone/"])
watch_sources = sources_phase("watch.sources", ["Sources/LumaCore/", "Sources/Platform/", "Sources/Watch/"])
fonts = [f"Resources/Manrope-{s}.ttf" for s in ["Regular", "Medium", "SemiBold"]]
tones = [f"Resources/luma-tone-{n}.wav" for n in [4,8,15]]
phone_resources = resources_phase("phone.resources", ["Resources/iOSAssets.xcassets", "Resources/PrivacyInfo.xcprivacy"] + fonts + tones)
watch_resources = resources_phase("watch.resources", ["Resources/WatchAssets.xcassets", "Resources/PrivacyInfo.xcprivacy"] + fonts)
phone_frameworks = obj("phone.frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
watch_frameworks = obj("watch.frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
embed_file = obj("embed.watch.file", "PBXBuildFile", fileRef=watch_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed = obj("embed.watch", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="$(CONTENTS_FOLDER_PATH)/Watch", dstSubfolderSpec=16, files=[embed_file], name="Embed Watch Content", runOnlyForDeploymentPostprocessing=0)
proxy = obj("watch.proxy", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType=1, remoteGlobalIDString=ident("watch.target"), remoteInfo="Luma Watch")
dependency = obj("watch.dependency", "PBXTargetDependency", target=ident("watch.target"), targetProxy=proxy)
phone_target = obj("phone.target", "PBXNativeTarget", buildConfigurationList=phone_configs, buildPhases=[phone_sources, phone_frameworks, phone_resources, embed], buildRules=[], dependencies=[dependency], name="Luma", productName="Luma", productReference=phone_product, productType="com.apple.product-type.application")
watch_target = obj("watch.target", "PBXNativeTarget", buildConfigurationList=watch_configs, buildPhases=[watch_sources, watch_frameworks, watch_resources], buildRules=[], dependencies=[], name="Luma Watch", productName="Luma Watch", productReference=watch_product, productType="com.apple.product-type.application")
project = obj("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastSwiftUpdateCheck": "1600", "LastUpgradeCheck": "1600", "TargetAttributes": {phone_target: {"CreatedOnToolsVersion": "16.0"}, watch_target: {"CreatedOnToolsVersion": "16.0"}}}, buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="ru", hasScannedForEncodings=0, knownRegions=["ru", "en", "Base"], mainGroup=main_group, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=[phone_target, watch_target])
output = ROOT / "Luma.xcodeproj"
output.mkdir(exist_ok=True)
(output / "project.pbxproj").write_text("// !$*UTF8*$!\n" + dump({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}) + "\n")

schemes = output / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
for name, target, product in [("Luma", phone_target, "Luma.app"), ("Luma Watch", watch_target, "Luma Watch.app")]:
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Luma.xcodeproj"/>'
    text = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
    (schemes / (name + ".xcscheme")).write_text(text)

# Metadata used by the static verifier; regenerated from the same project object graph.
(ROOT / "scripts/project-graph.json").write_text(json.dumps({"objects": objects, "rootObject": project}, indent=2))
print(f"Generated {output}; {len(objects)} project objects.")
