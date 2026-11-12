# SPDX-License-Identifier: MIT
"""Give a generated source rock stable ZIP metadata; retain every member's bytes."""
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
temporary = path.with_suffix(path.suffix + ".normalized")
with zipfile.ZipFile(path) as source, zipfile.ZipFile(temporary, "w") as destination:
    names = source.namelist()
    if len(names) != len(set(names)):
        raise ValueError("source rock contains duplicate ZIP members")
    for original in sorted(source.infolist(), key=lambda member: member.filename):
        member = zipfile.ZipInfo(original.filename, (1980, 1, 1, 0, 0, 0))
        member.create_system = original.create_system
        member.external_attr = original.external_attr
        member.internal_attr = original.internal_attr
        member.compress_type = original.compress_type
        member.comment = original.comment
        destination.writestr(member, source.read(original))
temporary.replace(path)
