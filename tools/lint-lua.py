#!/usr/bin/env python3
"""Catch Lua 5.4 constructs that only some builds reject.

The generic-for control variable is const in Lua 5.4. Assigning to it is a
runtime error on Arch's build and silently allowed on others, so it cannot be
caught by running the CLI on one machine.
"""

import re
import sys
from pathlib import Path

FOR = re.compile(r"^(\s*)for\s+([\w\s,]+?)\s+in\s")


def check(path: Path) -> list[str]:
    problems = []
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        match = FOR.match(line)
        if not match:
            continue
        indent = len(match.group(1))
        names = [n.strip() for n in match.group(2).split(",") if n.strip()]
        for j in range(i + 1, len(lines)):
            body = lines[j]
            if body.strip() and len(body) - len(body.lstrip()) <= indent:
                break
            for name in names:
                if re.match(rf"\s*{re.escape(name)}\s*=[^=]", body):
                    problems.append(
                        f"{path}:{j + 1}: assigns to for control variable "
                        f"'{name}' (declared on line {i + 1})"
                    )
    return problems


def main(argv: list[str]) -> int:
    files = [Path(a) for a in argv[1:]] or list(Path(".").rglob("*.lua"))
    problems = [p for f in files for p in check(f)]
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
