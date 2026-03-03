#!/usr/bin/env bash
set -euo pipefail

IFACE="${IFACE:-can0}"
FILE="${1:-}"
VERIFY=0
INCLUDE_DANG=0
STORE=0
TIMEOUT_S="${TIMEOUT_S:-0.4}"
INTERVAL_S="${INTERVAL_S:-0.01}"

usage(){
  echo "Usage: $0 <dump.csv> [--verify] [--include-dangerous] [--store]"
  exit 1
}
[[ -n "$FILE" && -f "$FILE" ]] || usage

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) VERIFY=1 ;;
    --include-dangerous) INCLUDE_DANG=1 ;;
    --store) STORE=1 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
  shift
done

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found" >&2; exit 1; }; }
need_cmd cansend
need_cmd candump
need_cmd stdbuf
need_cmd python3
need_cmd ip
need_cmd date

ip link show "$IFACE" >/dev/null 2>&1 || { echo "ERROR: interface '$IFACE' not found" >&2; exit 1; }

coproc CAND { stdbuf -oL candump -x "$IFACE"; }
CAND_PID=$!
trap 'kill "$CAND_PID" >/dev/null 2>&1 || true; wait "$CAND_PID" >/dev/null 2>&1 || true' EXIT

now_ns(){ date +%s%N; }

parse_candump_line(){
  local line="$1"
  local -a t
  read -ra t <<<"$line" || return 1
  local i canid
  for ((i=0; i<${#t[@]}; i++)); do
    if [[ "${t[i]}" =~ ^[0-9A-Fa-f]{3}$ ]]; then
      canid="${t[i]^^}"
      local b0="${t[i+2]:-}" b1="${t[i+3]:-}" b2="${t[i+4]:-}" b3="${t[i+5]:-}"
      local b4="${t[i+6]:-}" b5="${t[i+7]:-}" b6="${t[i+8]:-}" b7="${t[i+9]:-}"
      [[ "$b7" =~ ^[0-9A-Fa-f]{2}$ ]] || continue
      echo "$canid" "${b0^^}" "${b1^^}" "${b2^^}" "${b3^^}" "${b4^^}" "${b5^^}" "${b6^^}" "${b7^^}"
      return 0
    fi
  done
  return 1
}

wait_resp_raw(){
  local recv_id="$1" node_id="$2" rid="$3" cmd="$4" timeout_s="$5"
  local start_ns end_ns timeout_ns
  start_ns="$(now_ns)"
  timeout_ns="$(python3 - <<PY
print(int(float("${timeout_s}")*1e9))
PY
)"
  end_ns=$((start_ns + timeout_ns))

  while (( $(now_ns) < end_ns )); do
    local line=""
    if read -r -t 0.05 -u "${CAND[0]}" line; then
      local canid b0 b1 b2 b3 b4 b5 b6 b7
      if read -r canid b0 b1 b2 b3 b4 b5 b6 b7 < <(parse_candump_line "$line"); then
        [[ "$canid" == "${recv_id^^}" ]] || continue
        [[ "$b0" == "${node_id^^}" ]] || continue
        [[ "$b1" == "00" ]] || continue
        [[ "$b2" == "${cmd^^}" ]] || continue
        [[ "$b3" == "${rid^^}" ]] || continue
        echo "${b4}${b5}${b6}${b7}"
        return 0
      fi
    fi
  done
  return 1
}

echo "Restoring from: $FILE"
echo "iface=$IFACE verify=$VERIFY include_dangerous=$INCLUDE_DANG store=$STORE"

# CSV header:
# node_name,node_id_hex,recv_id_hex,rid_hex,rid_name,type,writable,dangerous,status,raw_le_hex,value

# We'll group by node for optional store (disable -> write many -> store)
current_node=""
current_node_id=""
current_recv_id=""
writes_in_node=0

flush_store_if_needed(){
  if [[ "$STORE" -eq 1 && "$writes_in_node" -gt 0 ]]; then
    # Storage parameters are only valid in disabled mode and may take up to ~30ms. :contentReference[oaicite:10]{index=10}
    cansend "$IFACE" "${current_node_id}#FFFFFFFFFFFFFFFD"       # disable
    sleep 0.02
    cansend "$IFACE" "7FF#${current_node_id}00AA0100000000"      # store
    sleep 0.05
    cansend "$IFACE" "${current_node_id}#FFFFFFFFFFFFFFFC"       # enable (optional)
    sleep 0.02
  fi
  writes_in_node=0
}

while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  [[ "${line:0:1}" != "#" ]] || continue
  [[ "$line" != node_name,* ]] || continue

  IFS=',' read -r node_name node_id_hex recv_id_hex rid_hex rid_name typ writable dangerous status raw_le_hex value <<<"$line"

  # skip if no data
  [[ "$status" == "OK" ]] || continue
  [[ -n "${raw_le_hex:-}" ]] || continue
  [[ "$writable" == "yes" ]] || continue

  if [[ "$dangerous" == "yes" && "$INCLUDE_DANG" -ne 1 ]]; then
    continue
  fi

  node_id_hex="${node_id_hex^^}"     # "01"
  recv_id_hex="${recv_id_hex^^}"     # "011"
  rid_hex="${rid_hex^^}"
  raw_le_hex="${raw_le_hex,,}"       # keep lower for cansend

  # if node changed, optionally store previous node
  if [[ "$current_node_id" != "$node_id_hex" ]]; then
    flush_store_if_needed
    current_node="$node_name"
    current_node_id="$node_id_hex"
    current_recv_id="$recv_id_hex"
  fi

  # write: 7FF# CANID_L 00 55 RID <raw(LE32)>
  cansend "$IFACE" "7FF#${node_id_hex}0055${rid_hex}${raw_le_hex}"
  writes_in_node=$((writes_in_node + 1))

  if [[ "$VERIFY" -eq 1 ]]; then
    # read back and compare
    cansend "$IFACE" "7FF#${node_id_hex}0033${rid_hex}00000000"
    if got="$(wait_resp_raw "$recv_id_hex" "$node_id_hex" "$rid_hex" "33" "$TIMEOUT_S")"; then
      if [[ "${got,,}" != "${raw_le_hex,,}" ]]; then
        echo "VERIFY NG: ${node_name} rid=0x${rid_hex} expected=${raw_le_hex} got=${got}" >&2
      else
        echo "VERIFY OK: ${node_name} rid=0x${rid_hex} raw=${raw_le_hex}"
      fi
    else
      echo "VERIFY TIMEOUT: ${node_name} rid=0x${rid_hex}" >&2
    fi
  fi

  sleep "$INTERVAL_S"
done < "$FILE"

# flush last node store
flush_store_if_needed

echo "OK: restore done"
