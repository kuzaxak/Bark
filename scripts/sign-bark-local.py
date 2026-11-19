#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Run the staged Chromium signer for a local, unnotarized Bark build."""

import argparse
from pathlib import Path
import sys

from bark_icloud_signing import prepare_profile, supports_cloud_share_activation
from chromium_sdk_layout import headers_directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--icloud-profile", type=Path, help="macOS Developer ID provisioning profile for Bark")
    parser.add_argument("stage", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    headers = headers_directory(Path(__file__).resolve().parents[1] / "Packages/BarkEngine")
    prepare_profile(args.stage, args.icloud_profile,
                    share_activation=args.icloud_profile is not None and supports_cloud_share_activation(headers))
    sys.path.insert(0, str((args.stage / "Bark Packaging").resolve(strict=True)))
    from signing import config_factory, driver

    class LocalBuild(config_factory.get_class()):
        @property
        def run_spctl_assess(self):
            # Gatekeeper distribution assessment requires a notarized build.
            return False

    config_factory.get_class = lambda: LocalBuild
    driver.main(["--identity", args.identity, "--input", str(args.stage),
                 "--output", str(args.output), "--notarize=none", "--disable-packaging"])


if __name__ == "__main__":
    main()
