#!/usr/bin/env python3
"""
generate_meeting_base.py — Generate/update meeting index Base file (obsidian-bases)
Creates a .base file in the vault for filtering meeting notes by date/tags/status.

Usage: generate_meeting_base.py <vault_path> [meeting_note_path]
"""

import json
import os
import sys
from datetime import datetime


BASE_TEMPLATE = """\
# Global filters apply to ALL views in the base
filters:
  - 'file.hasTag("会议笔记")'

# Define formula properties
formulas:
  date_fmt: 'file.ctime.format("YYYY-MM-DD")'

# Configure display names for properties
properties:
  date_fmt:
    displayName: Date

# Define one or more views
views:
  - type: table
    name: "All Meetings"
    limit: 50
    order:
      - file.name
      - date_fmt
      - tags
    summaries:
      date_fmt: Latest
"""


def generate_base(vault_path, output_name="会议索引"):
    """Generate meeting index .base file"""
    base_content = BASE_TEMPLATE

    # Write .base file
    base_dir = os.path.join(vault_path, "会议笔记")
    os.makedirs(base_dir, exist_ok=True)
    base_path = os.path.join(base_dir, f"{output_name}.base")

    with open(base_path, "w", encoding="utf-8") as f:
        f.write(base_content)

    print(f"Base file saved: {base_path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: generate_meeting_base.py <vault_path> [output_name]")
        sys.exit(1)

    vault_path = sys.argv[1]
    output_name = sys.argv[2] if len(sys.argv) > 2 else "会议索引"

    generate_base(vault_path, output_name)


if __name__ == "__main__":
    main()
