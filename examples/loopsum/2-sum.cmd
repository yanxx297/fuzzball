/export/scratch/Project/loopsum/fuzzball-loopsum/exec_utils/fuzzball \
-trace-insns -trace-temps -trace-decisions -trace-register-updates -trace-stores -trace-loads \
-table-limit 10 -trace-tables \
-check-condition-at '0x0804840f:mem[R_ESP:reg32_t+0x28:reg32_t]:reg32_t<>0xffffffff:reg32_t' \
-trace-conditions -trace-iterations \
-solve-final-pc -trace-assigns \
-use-loopsum -trace-loopsum-detailed -trace-loop-detailed \
-fuzz-start-addr 0x08048416 -symbolic-word 0x0804a01c=n \
-solver smtlib -solver-path ../../../../lib/z3/build/z3 \
-linux-syscalls -trace-stopping 2-sum  -- ./2-sum 0 2>&1
