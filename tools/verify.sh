#!/usr/bin/env bash
# After an unlock boot (no root): module log, driver errors, RM rate getter,
# tensor issue rate. RM_RATES points at read_sm_rates.py from
# https://github.com/JustAResearcher/gpu-unlock-ada (tools/read_sm_rates.py).
cd "$(dirname "$0")"
RM_RATES=${RM_RATES:-../../gpu-unlock-ada/tools/read_sm_rates.py}
echo "== module log"; journalctl -k -b --no-pager -q -o cat | grep -E '^turing_unlock|turing_unlock: unlocked' || echo "(no turing_unlock lines)"
echo "== NVRM Xid / errors"; journalctl -k -b --no-pager -q -o cat | grep -E 'NVRM: (Xid|GPU .*fallen|RmInitAdapter failed)' || echo "(none)"
echo "== RM rate getter (fmla32/imla4: 1=half, 0=full)"
python3 "$RM_RATES" --expect-uuid "$(nvidia-smi --query-gpu=uuid --format=csv,noheader)"
[[ -x mma_rate ]] || nvcc -O3 -arch=sm_75 -o mma_rate mma_rate.cu
[[ -x mma_validate ]] || nvcc -O3 -arch=sm_75 -o mma_validate mma_validate.cu
echo "== MMA issue rate"; ./mma_rate 20000
echo "== FP32-accumulate correctness"; ./mma_validate
