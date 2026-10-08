#!/usr/bin/env bash
# Export CANBoard fabrication and SMT assembly files without modifying the project.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bin/export_jlcpcb.sh [OUTPUT_DIRECTORY]

Export CANBoard Gerbers/drills, BOM and POS (CPL) for JLCPCB.
Default output: JLCPCB/ in the repository root. Relative output paths are
resolved from the current working directory. Existing output files are replaced.

Requires KiCad 10+ and Python 3 (standard library only).
Override executables with KICAD_CLI and PYTHON if needed.
Assembly exports include populated SMD components on both sides; through-hole
parts and footprints excluded from position files are omitted.
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi
if (( $# > 1 )) || [[ ${1:-} == -* ]]; then
    usage >&2
    exit 2
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PCB="$ROOT/CANBoard/CANBoard.kicad_pcb"
SCH="$ROOT/CANBoard/CANBoard.kicad_sch"
OUT=${1:-"$ROOT/JLCPCB"}
KICAD_CLI=${KICAD_CLI:-kicad-cli}
PYTHON=${PYTHON:-python3}

for executable in "$KICAD_CLI" "$PYTHON"; do
    if ! command -v "$executable" >/dev/null 2>&1; then
        echo "Required executable not found: $executable" >&2
        exit 1
    fi
done
VERSION=$("$KICAD_CLI" version)
MAJOR=${VERSION%%.*}
if [[ ! $MAJOR =~ ^[0-9]+$ ]] || (( MAJOR < 10 )); then
    echo "KiCad 10+ is required for zone refill during export; found $VERSION." >&2
    exit 1
fi
for source in "$PCB" "$SCH"; do
    if [[ ! -f $source ]]; then
        echo "Missing source: $source" >&2
        exit 1
    fi
done

# Stage each run independently so failed exports and old layers cannot enter a ZIP.
mkdir -p -- "$OUT"
OUT=$(cd -- "$OUT" && pwd)
WORK=$(mktemp -d "$OUT/.export-XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/gerbers"

echo "Exporting CANBoard with KiCad $VERSION"
"$KICAD_CLI" pcb export gerbers "$PCB" \
    --output "$WORK/gerbers/" \
    --layers 'F.Cu,In1.Cu,In2.Cu,B.Cu,F.Paste,B.Paste,F.SilkS,B.SilkS,F.Mask,B.Mask,Edge.Cuts' \
    --no-x2 --disable-aperture-macros --subtract-soldermask \
    --use-drill-file-origin --check-zones
"$KICAD_CLI" pcb export drill "$PCB" \
    --output "$WORK/gerbers/" --format excellon --drill-origin plot \
    --excellon-units mm --excellon-zeros-format decimal --excellon-separate-th
"$KICAD_CLI" sch export bom "$SCH" \
    --output "$WORK/bom.csv" --exclude-dnp \
    --fields 'Reference,Value,Footprint,LCSC' \
    --labels 'Designator,Comment,Footprint,LCSC Part #' \
    --group-by '' --ref-range-delimiter ''
"$KICAD_CLI" pcb export pos "$PCB" \
    --output "$WORK/pos.csv" --format csv --units mm --side both \
    --smd-only --exclude-dnp --use-drill-file-origin

"$PYTHON" - "$WORK" <<'PY'
import csv
import math
import re
import sys
from collections import defaultdict
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

work = Path(sys.argv[1])


def read_csv(name, reference):
    with (work / name).open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.DictReader(stream))
    result = {}
    for row in rows:
        ref = row[reference]
        if not ref or ref in result:
            raise SystemExit(f"Missing or duplicate reference in {name}: {ref!r}")
        result[ref] = row
    return result


def ref_key(ref):
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", ref)]


bom = read_csv("bom.csv", "Designator")
positions = read_csv("pos.csv", "Ref")
refs = sorted(bom.keys() & positions.keys(), key=ref_key)
if not refs:
    raise SystemExit("No populated SMD components common to schematic BOM and PCB positions.")

# Use the same references in both files, respecting exclusions from either source.
omitted = sorted(bom.keys() - positions.keys(), key=ref_key)
if omitted:
    print("Omitted from SMT assembly (no eligible PCB position): " + ", ".join(omitted))
omitted = sorted(positions.keys() - bom.keys(), key=ref_key)
if omitted:
    print("Omitted from SMT assembly (not in schematic BOM): " + ", ".join(omitted))

groups = defaultdict(list)
placement_rows = []
missing_lcsc = []
for ref in refs:
    component, position = bom[ref], positions[ref]
    footprint = component["Footprint"].split(":")[-1]
    if component["Comment"] != position["Val"] or footprint != position["Package"]:
        raise SystemExit(f"Schematic/PCB value or footprint mismatch for {ref}; update PCB first.")
    lcsc = component["LCSC Part #"].strip()
    if lcsc and not re.fullmatch(r"C[0-9]+", lcsc):
        raise SystemExit(f"Invalid LCSC part number for {ref}: {lcsc!r}")
    if not lcsc:
        missing_lcsc.append(ref)
    groups[(component["Comment"], footprint, lcsc)].append(ref)
    x, y, rotation = (float(position[field]) for field in ("PosX", "PosY", "Rot"))
    if not all(math.isfinite(value) for value in (x, y, rotation)):
        raise SystemExit(f"Non-finite position/rotation for {ref}")
    layer = position["Side"].lower()
    if layer not in ("top", "bottom"):
        raise SystemExit(f"Unknown board side for {ref}: {layer!r}")
    # Keep both sides in the same coordinate system as the Gerbers/drills.
    # Retain KiCad orientations; package-specific JLC rotations need preview review.
    placement_rows.append([ref, f"{x:.6f}mm", f"{y:.6f}mm", layer, f"{rotation % 360:.6f}"])

with (work / "CANBoard-BOM.csv").open("w", encoding="utf-8", newline="") as stream:
    writer = csv.writer(stream)
    writer.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
    for (comment, footprint, lcsc), designators in groups.items():
        writer.writerow([comment, ",".join(designators), footprint, lcsc])
with (work / "CANBoard-POS.csv").open("w", encoding="utf-8", newline="") as stream:
    writer = csv.writer(stream)
    writer.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    writer.writerows(placement_rows)

gerbers = sorted((work / "gerbers").iterdir())
if not any(path.suffix == ".drl" for path in gerbers):
    raise SystemExit("No drill files were generated.")
with ZipFile(work / "CANBoard-Gerbers.zip", "w", ZIP_DEFLATED) as archive:
    for path in gerbers:
        archive.write(path, path.name)

print(f"Exported {len(refs)} placements and {len(groups)} BOM groups.")
if missing_lcsc:
    print("WARNING: Select JLCPCB parts manually for: " + ", ".join(missing_lcsc), file=sys.stderr)
PY

for artifact in CANBoard-Gerbers.zip CANBoard-BOM.csv CANBoard-POS.csv; do
    mv -f -- "$WORK/$artifact" "$OUT/$artifact"
    echo "Created $OUT/$artifact"
done
echo 'Review component matches and orientations in the JLCPCB assembly preview before ordering.'
