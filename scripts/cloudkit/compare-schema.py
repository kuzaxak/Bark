# Licensed under GPL-3.0. See LICENSE.
"""Check CloudKit schema export types, fields, indexes and grants."""

import argparse
from pathlib import Path
import re


NAME = r'[A-Za-z_][A-Za-z_0-9]*'
IDENTIFIER = rf'(?:"({NAME}(?:\.{NAME})*)"|({NAME}))'
RECORD = re.compile(rf'\bRECORD\s+TYPE\s+{IDENTIFIER}\s*\((.*?)\)\s*;', re.DOTALL)
FIELD = re.compile(rf'{IDENTIFIER}\s+(ENCRYPTED\s+)?({NAME}(?:\s*<\s*{NAME}\s*>)?)((?:\s+{NAME})*)')
GRANT = re.compile(rf'GRANT\s+({NAME})\s+TO\s+{IDENTIFIER}')


def schema(path):
    text = path.read_text(encoding="utf-8")
    records = {}
    for quoted, bare, entries in RECORD.findall(text):
        name = quoted or bare
        if name in records:
            raise ValueError(f"{path}: duplicate record type {name}")
        fields = {}
        grants = set()
        for declaration in filter(None, map(str.strip, entries.split(","))):
            if grant := GRANT.fullmatch(declaration):
                privilege, quoted, bare = grant.groups()
                grants.add((privilege, quoted or bare))
                continue
            field = FIELD.fullmatch(declaration)
            if field is None:
                raise ValueError(f"{path}: unrecognized declaration in {name}: {declaration}")
            quoted, bare, encrypted, kind, modifiers = field.groups()
            field_name = quoted or bare
            if field_name in fields:
                raise ValueError(f"{path}: duplicate field {name}.{field_name}")
            fields[field_name] = ("ENCRYPTED " * bool(encrypted) + "".join(kind.split()),
                                  set(modifiers.split()))
        records[name] = fields, grants
    if not records:
        raise ValueError(f"{path}: no record types found")
    return records


def differences(required, available):
    for record, (required_fields, required_grants) in required.items():
        if record not in available:
            yield record
            continue
        fields, grants = available[record]
        for name, (expected_type, required_modifiers) in required_fields.items():
            if name not in fields:
                yield f"{record}.{name}"
                continue
            actual_type, modifiers = fields[name]
            if expected_type != actual_type:
                yield f"{record}.{name}: expected {expected_type}, found {actual_type}"
            for modifier in sorted(required_modifiers - modifiers):
                yield f"{record}.{name}: missing {modifier}"
        for privilege, principal in sorted(required_grants - grants):
            yield f'{record}: missing GRANT {privilege} TO "{principal}"'
        for privilege, principal in sorted(grants - required_grants):
            yield f'{record}: unexpected GRANT {privilege} TO "{principal}"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tracked", type=Path)
    parser.add_argument("exported", type=Path)
    args = parser.parse_args()
    try:
        exported = schema(args.exported)
        missing = list(differences(schema(args.tracked), exported))
        # CloudKit creates this system type when a real zone share is saved in Development.
        share = exported.get("cloudkit.share")
        if share is None:
            missing.append("cloudkit.share")
        else:
            fields, _ = share
            title = fields.get("cloudkit.title")
            if title is None:
                missing.append("cloudkit.share.cloudkit.title")
            elif title[0] != "STRING":
                missing.append(f"cloudkit.share.cloudkit.title: expected STRING, found {title[0]}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    if missing:
        report = "\n".join(f"  {problem}" for problem in missing)
        parser.exit(1, f"Production schema does not meet Bark requirements:\n{report}\n"
                    "Import the app schema into Development. For a missing cloudkit.share, save a real "
                    "zone-wide CKShare in Development. Review and deploy the changes before releasing.\n")
    print("Production schema meets Bark's record, field, index and grant requirements.")


if __name__ == "__main__":
    main()
