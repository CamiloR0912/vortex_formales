#!/bin/bash
# Corre ./vortex sobre cada .vx y compara la salida con su .out esperado.
#   bash tests/run_tests.sh            compara
#   bash tests/run_tests.sh --update   regenera los .out con la salida actual
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0
for vx in tests/*.vx tests/*/*.vx; do
    out="${vx%.vx}.out"
    if [ "$1" = "--update" ]; then
        ./vortex "$vx" > "$out"
        continue
    fi
    if ./vortex "$vx" | diff -q - "$out" > /dev/null; then
        echo "PASS  $vx"; pass=$((pass + 1))
    else
        echo "FAIL  $vx"; fail=$((fail + 1))
    fi
done
[ "$1" = "--update" ] && { echo "Archivos .out regenerados."; exit 0; }
echo "$pass passed, $fail failed."
[ "$fail" -eq 0 ]
