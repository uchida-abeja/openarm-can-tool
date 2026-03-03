#!/usr/bin/env bash
set -euo pipefail

IFACE="${IFACE:-can0}"
OUT="${OUT:-openarm_registers_$(date +%Y%m%d_%H%M%S).csv}"
TIMEOUT_S="${TIMEOUT_S:-0.4}"   # 1リクエストあたり待ち時間
INTERVAL_S="${INTERVAL_S:-0.01}" # リクエスト間隔

declare -A NODE_NAME=(
  [1]="joint_1"
  [2]="joint_2"
  [3]="joint_3"
  [4]="joint_4"
  [5]="joint_5"
  [6]="joint_6"
  [7]="joint_7"
  [8]="gripper"
)

# ---- Register list (as exhaustive as possible, based on Damiao manual) ----
# Damiao manual register table includes 0x00..0x24 and 0x32. It also mentions precise position at 0x50. :contentReference[oaicite:4]{index=4}
RIDS=(
  00 01 02 03 04 05 06
  07 09 0A
  0B 0C 0D 0E 0F 10 11 12 13 14
  15 16 17
  18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24
  32
  50
)

# Meta: name/type/writable/dangerous
# type: f32 | u32 | unknown
declare -A RID_NAME RID_TYPE RID_WRITABLE RID_DANG

# ---- Populate from manual table (and a few inferred) ----
RID_NAME[00]="UV_Value";     RID_TYPE[00]="f32"; RID_WRITABLE[00]="yes"; RID_DANG[00]="no"
RID_NAME[01]="KT_Value";     RID_TYPE[01]="f32"; RID_WRITABLE[01]="yes"; RID_DANG[01]="no"
RID_NAME[02]="OT_Value";     RID_TYPE[02]="f32"; RID_WRITABLE[02]="yes"; RID_DANG[02]="no"
RID_NAME[03]="OC_Value";     RID_TYPE[03]="f32"; RID_WRITABLE[03]="yes"; RID_DANG[03]="no"
RID_NAME[04]="ACC";          RID_TYPE[04]="f32"; RID_WRITABLE[04]="yes"; RID_DANG[04]="no"
RID_NAME[05]="DEC";          RID_TYPE[05]="f32"; RID_WRITABLE[05]="yes"; RID_DANG[05]="no"
RID_NAME[06]="MAX_SPD";      RID_TYPE[06]="f32"; RID_WRITABLE[06]="yes"; RID_DANG[06]="no"

RID_NAME[07]="MST_ID(Feedback CAN ID)"; RID_TYPE[07]="u32"; RID_WRITABLE[07]="yes"; RID_DANG[07]="yes"   # 危険: 返りID変わる
RID_NAME[09]="TIMEOUT";      RID_TYPE[09]="u32"; RID_WRITABLE[09]="yes"; RID_DANG[09]="yes"   # 危険: 0にすると応答しない可能性 :contentReference[oaicite:5]{index=5}
RID_NAME[0A]="CTRL_MODE";    RID_TYPE[0A]="u32"; RID_WRITABLE[0A]="yes"; RID_DANG[0A]="no"    # 動作モード

RID_NAME[0B]="Damp";         RID_TYPE[0B]="f32"; RID_WRITABLE[0B]="no";  RID_DANG[0B]="no"
RID_NAME[0C]="Inertia";      RID_TYPE[0C]="f32"; RID_WRITABLE[0C]="no";  RID_DANG[0C]="no"
RID_NAME[0D]="hw_ver";       RID_TYPE[0D]="u32"; RID_WRITABLE[0D]="no";  RID_DANG[0D]="no"
RID_NAME[0E]="sw_ver";       RID_TYPE[0E]="u32"; RID_WRITABLE[0E]="no";  RID_DANG[0E]="no"
RID_NAME[0F]="SN";           RID_TYPE[0F]="u32"; RID_WRITABLE[0F]="no";  RID_DANG[0F]="no"
RID_NAME[10]="NPP";          RID_TYPE[10]="u32"; RID_WRITABLE[10]="no";  RID_DANG[10]="no"
RID_NAME[11]="Rs";           RID_TYPE[11]="f32"; RID_WRITABLE[11]="no";  RID_DANG[11]="no"
RID_NAME[12]="Ls";           RID_TYPE[12]="f32"; RID_WRITABLE[12]="no";  RID_DANG[12]="no"
RID_NAME[13]="Flux";         RID_TYPE[13]="f32"; RID_WRITABLE[13]="no";  RID_DANG[13]="no"
RID_NAME[14]="Gr";           RID_TYPE[14]="f32"; RID_WRITABLE[14]="no";  RID_DANG[14]="no"

RID_NAME[15]="PMAX";         RID_TYPE[15]="f32"; RID_WRITABLE[15]="yes"; RID_DANG[15]="no"
RID_NAME[16]="VMAX";         RID_TYPE[16]="f32"; RID_WRITABLE[16]="yes"; RID_DANG[16]="no"
RID_NAME[17]="TMAX";         RID_TYPE[17]="f32"; RID_WRITABLE[17]="yes"; RID_DANG[17]="no"

RID_NAME[18]="I_BW";         RID_TYPE[18]="f32"; RID_WRITABLE[18]="yes"; RID_DANG[18]="no"
RID_NAME[19]="KP_ASR";       RID_TYPE[19]="f32"; RID_WRITABLE[19]="yes"; RID_DANG[19]="no"
RID_NAME[1A]="KI_ASR";       RID_TYPE[1A]="f32"; RID_WRITABLE[1A]="yes"; RID_DANG[1A]="no"
RID_NAME[1B]="KP_APR";       RID_TYPE[1B]="f32"; RID_WRITABLE[1B]="yes"; RID_DANG[1B]="no"
RID_NAME[1C]="KI_APR";       RID_TYPE[1C]="f32"; RID_WRITABLE[1C]="yes"; RID_DANG[1C]="no"
RID_NAME[1D]="OV_Value";     RID_TYPE[1D]="f32"; RID_WRITABLE[1D]="yes"; RID_DANG[1D]="no"
RID_NAME[1E]="GREF";         RID_TYPE[1E]="f32"; RID_WRITABLE[1E]="yes"; RID_DANG[1E]="no"
RID_NAME[1F]="Deta";         RID_TYPE[1F]="f32"; RID_WRITABLE[1F]="yes"; RID_DANG[1F]="no"
RID_NAME[20]="V_BW";         RID_TYPE[20]="f32"; RID_WRITABLE[20]="yes"; RID_DANG[20]="no"
RID_NAME[21]="IQ_c1";        RID_TYPE[21]="f32"; RID_WRITABLE[21]="yes"; RID_DANG[21]="no"
RID_NAME[22]="VL_c1";        RID_TYPE[22]="f32"; RID_WRITABLE[22]="yes"; RID_DANG[22]="no"
RID_NAME[23]="can_br";       RID_TYPE[23]="u32"; RID_WRITABLE[23]="yes"; RID_DANG[23]="yes"  # 危険: baud変わる :contentReference[oaicite:6]{index=6}
RID_NAME[24]="sub_ver";      RID_TYPE[24]="u32"; RID_WRITABLE[24]="no";  RID_DANG[24]="no"
RID_NAME[32]="u_off";        RID_TYPE[32]="f32"; RID_WRITABLE[32]="no";  RID_DANG[32]="no"

RID_NAME[50]="Precise_Position"; RID_TYPE[50]="f32"; RID_WRITABLE[50]="no"; RID_DANG[50]="no"  # マニュアルが0x50言及 :contentReference[oaicite:7]{index=7}

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found" >&2; exit 1; }; }
need_cmd cansend
need_cmd candump
need_cmd stdbuf
need_cmd python3
need_cmd ip
need_cmd date

ip link show "$IFACE" >/dev/null 2>&1 || { echo "ERROR: interface '$IFACE' not found" >&2; exit 1; }

# candump: use NORMAL format (no -L). -x prints bytes in hex.
coproc CAND { stdbuf -oL candump -x "$IFACE"; }
CAND_PID=$!
trap 'kill "$CAND_PID" >/dev/null 2>&1 || true; wait "$CAND_PID" >/dev/null 2>&1 || true' EXIT

# monotonic-ish now (ns)
now_ns(){ date +%s%N; }

decode_u32(){
  local lehex="$1"
  python3 - <<PY
import struct
print(struct.unpack("<I", bytes.fromhex("${lehex}"))[0])
PY
}
decode_f32(){
  local lehex="$1"
  python3 - <<PY
import struct
print(struct.unpack("<f", bytes.fromhex("${lehex}"))[0])
PY
}

# Parse a candump line and echo: CANID B0 B1 B2 B3 B4 B5 B6 B7
# Robust to optional timestamps because we search for first 3-hex token, then take bytes after [DLC].
parse_candump_line(){
  local line="$1"
  local -a t
  read -ra t <<<"$line" || return 1

  local i canid
  for ((i=0; i<${#t[@]}; i++)); do
    if [[ "${t[i]}" =~ ^[0-9A-Fa-f]{3}$ ]]; then
      canid="${t[i]^^}"
      # Expect: canid [DLC] b0 b1 ... b7
      # i+1 is [8] or [08]
      local b0="${t[i+2]:-}" b1="${t[i+3]:-}" b2="${t[i+4]:-}" b3="${t[i+5]:-}"
      local b4="${t[i+6]:-}" b5="${t[i+7]:-}" b6="${t[i+8]:-}" b7="${t[i+9]:-}"
      [[ "$b7" =~ ^[0-9A-Fa-f]{2}$ ]] || continue
      echo "$canid" "${b0^^}" "${b1^^}" "${b2^^}" "${b3^^}" "${b4^^}" "${b5^^}" "${b6^^}" "${b7^^}"
      return 0
    fi
  done
  return 1
}

# Wait for response: recv_id, node_id, rid, cmd(33)
# Return raw LE hex (D4..D7) and also full bytes if needed.
wait_resp_raw(){
  local recv_id="$1"   # e.g. "011"
  local node_id="$2"   # e.g. "01"
  local rid="$3"       # e.g. "16"
  local cmd="$4"       # "33"
  local timeout_s="$5"

  local start_ns end_ns
  start_ns="$(now_ns)"
  # Convert seconds to ns (float-safe-ish using python once)
  local timeout_ns
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

{
  echo "# OpenArm Damiao register dump"
  echo "# iface=${IFACE}"
  echo "# generated_at=$(date -Is)"
  echo "node_name,node_id_hex,recv_id_hex,rid_hex,rid_name,type,writable,dangerous,status,raw_le_hex,value"
} > "$OUT"

for nid in {1..8}; do
  node="${NODE_NAME[$nid]}"
  node_id_hex="$(printf "%02X" "$nid")"
  recv_id_hex="$(printf "%03X" "$((0x10 + nid))")"

  for rid in "${RIDS[@]}"; do
    rid="${rid^^}"
    rid_name="${RID_NAME[$rid]:-UNKNOWN}"
    rid_type="${RID_TYPE[$rid]:-unknown}"
    rid_w="${RID_WRITABLE[$rid]:-no}"
    rid_d="${RID_DANG[$rid]:-no}"

    # read: 7FF# CANID_L 00 33 RID 00 00 00 00
    cansend "$IFACE" "7FF#${node_id_hex}0033${rid}00000000"

    if raw_le_hex="$(wait_resp_raw "$recv_id_hex" "$node_id_hex" "$rid" "33" "$TIMEOUT_S")"; then
      local_val=""
      if [[ "$rid_type" == "f32" ]]; then
        local_val="$(decode_f32 "$raw_le_hex")"
      elif [[ "$rid_type" == "u32" ]]; then
        local_val="$(decode_u32 "$raw_le_hex")"
      else
        # unknown: print both interpretations
        local_val="f32=$(decode_f32 "$raw_le_hex");u32=$(decode_u32 "$raw_le_hex")"
      fi
      echo "${node},${node_id_hex},${recv_id_hex},${rid},${rid_name},${rid_type},${rid_w},${rid_d},OK,${raw_le_hex},${local_val}" >> "$OUT"
    else
      echo "${node},${node_id_hex},${recv_id_hex},${rid},${rid_name},${rid_type},${rid_w},${rid_d},TIMEOUT,," >> "$OUT"
      echo "WARN: timeout node=${node} (0x${node_id_hex}) rid=0x${rid} on ${IFACE}" >&2
    fi

    sleep "$INTERVAL_S"
  done
done

echo "OK: saved to ${OUT}"
