#!/usr/bin/env bash
cd "C:/Users/mmakk/AppData/Local/Temp/claude/C--Users-mmakk-Claude-Code/005bfed5-7c98-401c-ab0d-bf0b448997e4/scratchpad/sim_reserved"
PY="$LOCALAPPDATA/Programs/Python/Python312/python.exe"
# wait for battery + pareto to finish (final tables are long)
until [ "$(wc -l < batt_full.txt)" -gt 5 ] && [ "$(wc -l < pareto.txt)" -gt 5 ]; do sleep 5; done
echo "battery+pareto done" > drive.log
# now run the focused probes with freed cores
"$PY" q3_sizing.py > q3.txt 2> q3.err
echo "q3 done" >> drive.log
"$PY" q4_latency.py > q4.txt 2> q4.err
echo "q4 done" >> drive.log
echo "ALLDONE" > DONE.marker
