#!/usr/bin/env python3
"""Set the Omarchy shell's idle timeouts in ~/.config/omarchy/shell.json.

The shell's config API hands bar plugins only the `bar` section, so the
panel writes `idle` itself. The shell watches shell.json and applies the
change live. Everything else in the file is kept as it is.

Usage: set-idle.py screensaver=150 [lock=300]   (seconds, 0 = off)
"""

import json
import os
import sys
import tempfile

KEYS = ("screensaver", "lock")


def main():
    updates = {}
    for arg in sys.argv[1:]:
        key, _, value = arg.partition("=")
        if key not in KEYS or not value.isdigit():
            sys.exit("bad argument: %r" % arg)
        updates[key] = int(value)
    if not updates:
        sys.exit("nothing to set")

    path = os.path.join(os.path.expanduser("~"), ".config", "omarchy", "shell.json")
    with open(path, "r", encoding="utf-8") as f:
        config = json.load(f)  # refuse to touch a file that is not valid JSON
    if not isinstance(config, dict):
        sys.exit("shell.json is not an object")

    idle = config.get("idle")
    if not isinstance(idle, dict):
        idle = config["idle"] = {}
    if all(idle.get(k) == v for k, v in updates.items()):
        return
    idle.update(updates)

    # Same layout the shell writes (JSON.stringify(config, null, 2)), swapped
    # in atomically with the original file's permissions.
    mode = os.stat(path).st_mode & 0o777
    fd, tmp = tempfile.mkstemp(prefix=".shell.json.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


if __name__ == "__main__":
    main()
