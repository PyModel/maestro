#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

SUITE_TIMEOUT="${MAESTRO_SUITE_TIMEOUT_SEC-600}"
suite_timeout_invalid=0
case "$SUITE_TIMEOUT" in
  ''|*[!0-9]*) suite_timeout_invalid=1 ;;
  *) [ "$SUITE_TIMEOUT" -ge 1 ] 2>/dev/null || suite_timeout_invalid=1 ;;
esac
if [ "$suite_timeout_invalid" -eq 1 ]; then
  printf 'MAESTRO_TEST: ignoring invalid MAESTRO_SUITE_TIMEOUT_SEC=%s; using 600s\n' "$SUITE_TIMEOUT"
  SUITE_TIMEOUT=600
fi

suite_descendants() { # root pid
  ps -axo pid=,ppid= 2>/dev/null | awk -v root="$1" '
    { pid[NR] = $1; parent[$1] = $2 }
    END {
      selected[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= NR; i++) {
          current = pid[i]
          if (!selected[current] && selected[parent[current]]) {
            selected[current] = 1
            changed = 1
          }
        }
      }
      for (i = 1; i <= NR; i++) if (pid[i] != root && selected[pid[i]]) print pid[i]
    }
  '
}

terminate_suite_tree() { # process-group leader
  local root="$1" descendants descendant ticks=0 alive
  descendants=$(suite_descendants "$root")
  kill -TERM -"$root" 2>/dev/null || :
  for descendant in $descendants; do kill -TERM "$descendant" 2>/dev/null || :; done
  while [ "$ticks" -lt 50 ]; do
    alive=0
    kill -0 -"$root" 2>/dev/null && alive=1
    for descendant in $descendants; do
      kill -0 "$descendant" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 1 ] || break
    sleep 0.1
    ticks=$((ticks + 1))
  done
  kill -KILL -"$root" 2>/dev/null || :
  for descendant in $descendants; do kill -KILL "$descendant" 2>/dev/null || :; done
}

suite_inventory() {
    local suite_path suite
    for suite_path in "$TEST_DIR"/*.sh; do
        suite="${suite_path##*/}"
        [ "$suite" = run.sh ] || printf '%s\n' "$suite"
    done | LC_ALL=C sort
}

suite_cost() {
    case "$1" in
        liveness.sh) printf '%s\n' 166 ;;
        stop-report.sh) printf '%s\n' 141 ;;
        lease.sh) printf '%s\n' 83 ;;
        bounded-calls.sh) printf '%s\n' 58 ;;
        detection.sh) printf '%s\n' 39 ;;
        job-lock.sh) printf '%s\n' 30 ;;
        scout.sh) printf '%s\n' 25 ;;
        discussion.sh) printf '%s\n' 22 ;;
        commit-invariance.sh) printf '%s\n' 9 ;;
        provenance-edge.sh) printf '%s\n' 8 ;;
        orphan-lifecycle.sh) printf '%s\n' 8 ;;
        gate.sh) printf '%s\n' 7 ;;
        shared-git-dir.sh) printf '%s\n' 4 ;;
        preflight.sh) printf '%s\n' 4 ;;
        manual-check-and-submodules.sh) printf '%s\n' 4 ;;
        install.sh) printf '%s\n' 4 ;;
        runner-timeout.sh) printf '%s\n' 2 ;;
        model-selector.sh) printf '%s\n' 2 ;;
        *) printf '%s\n' 60 ;;
    esac
}

usage() {
    printf 'usage: %s [--list | --shard I/N | suite ...]\n' "$0" >&2
}

inventory=$(suite_inventory)
inventory_suites=()
while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    inventory_suites[${#inventory_suites[@]}]="$suite"
done <<EOF
$inventory
EOF

suites=()
shard_index=''
shard_count=''
if [ "$#" -eq 0 ]; then
    suites=("${inventory_suites[@]}")
else
    case "$1" in
        --list)
            [ "$#" -eq 1 ] || { usage; exit 2; }
            printf '%s\n' "${inventory_suites[@]}"
            exit 0
            ;;
        --shard)
            if [ "$#" -ne 2 ]; then
                usage
                exit 2
            fi
            shard_spec="$2"
            case "$shard_spec" in
                */*) ;;
                *)
                    usage
                    exit 2
                    ;;
            esac
            case "$shard_spec" in
                ''|*/*/*|/*|*/|*[!0-9/]*)
                    usage
                    exit 2
                    ;;
            esac
            shard_index_text="${shard_spec%%/*}"
            shard_count_text="${shard_spec#*/}"
            shard_index=$((10#$shard_index_text))
            shard_count=$((10#$shard_count_text))
            if [ "$shard_index" -lt 1 ] ||
                [ "$shard_count" -lt 1 ] ||
                [ "$shard_index" -gt "$shard_count" ]; then
                usage
                exit 2
            fi
            ;;
        *)
            suites=("$@")
            ;;
    esac
fi

if [ -n "$shard_index" ]; then
    ordered_suites=()
    ordered_costs=()
    for suite in "${inventory_suites[@]}"; do
        cost=$(suite_cost "$suite")
        position=0
        while [ "$position" -lt "${#ordered_suites[@]}" ] &&
            [ "${ordered_costs[$position]}" -ge "$cost" ]; do
            position=$((position + 1))
        done
        index=${#ordered_suites[@]}
        while [ "$index" -gt "$position" ]; do
            previous=$((index - 1))
            ordered_suites[$index]="${ordered_suites[$previous]}"
            ordered_costs[$index]="${ordered_costs[$previous]}"
            index=$previous
        done
        ordered_suites[$position]="$suite"
        ordered_costs[$position]="$cost"
    done

    shard_loads=()
    assigned_shards=()
    for ((shard = 1; shard <= shard_count; shard++)); do
        shard_loads[$shard]=0
    done
    for ((suite_index = 0; suite_index < ${#ordered_suites[@]}; suite_index++)); do
        target=1
        cost="${ordered_costs[$suite_index]}"
        for ((shard = 2; shard <= shard_count; shard++)); do
            if [ "${shard_loads[$shard]}" -lt "${shard_loads[$target]}" ]; then
                target=$shard
            fi
        done
        assigned_shards[$suite_index]=$target
        shard_loads[$target]=$((shard_loads[$target] + cost))
    done

    suites=()
    for ((suite_index = 0; suite_index < ${#ordered_suites[@]}; suite_index++)); do
        if [ "${assigned_shards[$suite_index]}" -eq "$shard_index" ]; then
            suites[${#suites[@]}]="${ordered_suites[$suite_index]}"
        fi
    done
fi

for suite in "${suites[@]}"; do
  set -m
  bash "$TEST_DIR/$suite" &
  pid=$!
  set +m
  elapsed=0
  timed_out=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$SUITE_TIMEOUT" ]; then
      timed_out=1
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if [ "$timed_out" -eq 1 ]; then
    terminate_suite_tree "$pid"
  fi
  wait "$pid" 2>/dev/null
  rc=$?
  [ "$timed_out" -eq 0 ] || rc=124

  if [ "$timed_out" -eq 1 ]; then
    printf 'TIMEOUT  %s (rc=124)\n' "$suite"
    FAIL=$((FAIL+1))
  elif [ "$rc" -eq 0 ]; then
    printf 'PASS  %s\n' "$suite"
    PASS=$((PASS+1))
  else
    printf 'FAIL  %s (rc=%d)\n' "$suite" "$rc"
    FAIL=$((FAIL+1))
  fi
done

printf 'SUMMARY: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
