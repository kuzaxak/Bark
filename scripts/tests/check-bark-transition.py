#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Headless update selection checks against the Sparkle source locked by Nook."""

import argparse
from pathlib import Path
import plistlib
import subprocess
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[2]
LEGACY = "202611050920"
TRANSITION = "202611200001"
BARK = "202611200002"


def method(source, beginning, following):
    return source[source.index(beginning):source.index(following)]


def set_up_bundle(path, identifier, name, version, updater_name=None):
    contents = path / "Contents"
    contents.mkdir(parents=True)
    info = dict(CFBundleIdentifier=identifier, CFBundleName=name, CFBundleDisplayName=name,
                CFBundlePackageType="APPL", CFBundleVersion=version)
    if updater_name is not None:
        info["SUBundleName"] = updater_name
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))


def check_sparkle(sparkle, working):
    autoupdate = sparkle / "Autoupdate"
    framework = sparkle / "Sparkle"
    selector = method((autoupdate / "SUInstaller.m").read_text(),
                      "+ (nullable NSString *)installSourcePathInUpdateFolder:",
                      "+ (nullable id<SUInstallerProtocol>)installerForHost:")
    name = method((framework / "SUHost.m").read_text(),
                  "- (NSString * _Nonnull)name", "- (BOOL)validVersion")
    source = working / "selection.m"
    source.write_text('''
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import "SUStandardVersionComparator.h"
#define SPARKLE_BUILD_PACKAGE_SUPPORT 1
#define SULog(...) ((void)0)

@interface SUHost : NSObject
@property NSBundle *bundle;
- (NSString *)bundlePath;
- (NSString *)name;
- (id)objectForInfoDictionaryKey:(NSString *)key;
@end
@implementation SUHost
- (NSString *)bundlePath { return self.bundle.bundlePath; }
- (id)objectForInfoDictionaryKey:(NSString *)key { return [self.bundle objectForInfoDictionaryKey:key]; }
''' + name + '''
@end
@interface SUInstaller : NSObject
@end
@implementation SUInstaller
''' + selector + '''
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSCAssert(argc == 5, @"Expected a host, archive and version pair");
        SUHost *host = [SUHost new];
        host.bundle = [NSBundle bundleWithPath:@(argv[1])];
        NSString *picked = [SUInstaller installSourcePathInUpdateFolder:@(argv[2]) forHost:host
                                                               isPackage:NULL isGuided:NULL];
        NSComparisonResult order = [[SUStandardVersionComparator defaultComparator]
                                    compareVersion:@(argv[3]) toVersion:@(argv[4])];
        printf("%s\\n%ld\\n", picked.lastPathComponent.UTF8String ?: "-", (long)order);
    }
    return 0;
}
''')
    binary = working / "selection"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    "-DSPU_OBJC_DIRECT=", "-Wno-nullability-completeness", "-I", framework, "-I", sparkle,
                    source, framework / "SUStandardVersionComparator.m", "-o", binary], check=True)

    published = working / "before" / "Renamed Nook.app"
    first = working / "transition" / "Nook.app"
    second = working / "bark" / "Bark.app"
    installed = working / "installed" / "Renamed Nook.app"
    next_bark = working / "next" / "Bark.app"
    transition_name = plistlib.loads((ROOT / "Nook/Info.plist").read_bytes())["SUBundleName"]
    set_up_bundle(published, "ee.qdo.nook", "Nook", LEGACY)
    set_up_bundle(first, "ee.qdo.nook", "Nook", TRANSITION, transition_name)
    set_up_bundle(second, "ee.qdo.bark", "Bark", BARK)
    set_up_bundle(installed, "ee.qdo.bark", "Bark", BARK)
    set_up_bundle(next_bark, "ee.qdo.bark", "Bark", "202611200003")

    def check(host, candidate, old, new, selected, order=-1):
        result = subprocess.check_output([binary, host, candidate.parent, old, new], text=True)
        assert result.splitlines() == [selected, str(order)], result

    check(published, second, LEGACY, BARK, "-")
    check(published, first, LEGACY, TRANSITION, "Nook.app")
    for filename in ("Nook.app", "Renamed Nook.app"):
        host = working / "transition-installed" / filename
        set_up_bundle(host, "ee.qdo.nook", "Nook", TRANSITION, transition_name)
        check(host, second, TRANSITION, BARK, "Bark.app")
        check(host, second, TRANSITION, "125", "Bark.app", 1)
    check(installed, next_bark, BARK, "202611200003", "Bark.app")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sparkle_source", type=Path, help="extracted source at the Sparkle commit in Package.resolved")
    args = parser.parse_args()
    with TemporaryDirectory(prefix="nook-bark-transition-") as directory:
        working = Path(directory)
        feeds = working / "feeds"
        subprocess.run(["xcrun", "swiftc", ROOT / "App/BarkTransitionFeed.swift",
                        ROOT / "scripts/tests/BarkTransitionFeedCheck.swift", "-o", feeds], check=True)
        subprocess.run([feeds], check=True)
        check_sparkle(args.sparkle_source, working)
    print("Pinned Sparkle selects both transition hops and a subsequent Bark update.")


if __name__ == "__main__":
    main()
