# Copyright 2026 The Chromium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""Retain the profile digest for Bark's official browser compile in offline Siso."""

load("@builtin//encoding.star", "json")
load("@builtin//struct.star", "module")
load("@config//main.star", upstream_init = "init")

def _read_browser_profile(ctx, cmd):
    if any([arg.startswith("@") for arg in cmd.args]):
        fail("Unexpected response file in Bark's browser PGO compile")
    profiles = [arg.removeprefix("-fprofile-use=") for arg in cmd.args if arg.startswith("-fprofile-use=")]
    if len(profiles) != 1:
        fail("Bark's browser compile must use one explicit PGO profile")
    ctx.fs.read(ctx.fs.canonpath(profiles[0]))

def init(ctx):
    upstream = upstream_init(ctx)
    config = json.decode(upstream.step_config)
    config["rules"].append({
        "name": "bark/profile_compile",
        "action": "cxx",
        "action_outs": ["./obj/chrome/browser/core/browser_process_impl.o"],
        "command_prefix": "./bark_official_pgo_cc_v1 ",
        "handler": "bark_profile_compile",
    })
    handlers = dict(upstream.handlers)
    handlers["bark_profile_compile"] = _read_browser_profile
    return module("config", step_config = json.encode(config), filegroups = upstream.filegroups, handlers = handlers)
