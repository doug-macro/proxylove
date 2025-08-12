#!/bin/bash
# Proxy Love — macOS bash 3.2 compatible, hardened loop
# - Masters READ-ONLY
# - Proxies sanitized and fixed
# - Robust name matching (+ duration fallback)
# - FFmpeg never reads stdin (-nostdin)
# - Each loop iteration closes its stdin (</dev/null)

set -euo pipefail

RENAME_TO_MASTER=false
ENABLE_DURATION_FALLBACK=true
PILLAR_COLOR="gray"   # "gray" or "black" etc.

# ---------------- AppleScript helpers ----------------
as_dialog() { /usr/bin/osascript - "$@" <<'APPLESCRIPT'
on run argv
  display dialog (item 1 of argv) buttons {"OK"} default button 1 with icon note
end run
APPLESCRIPT
}

as_pick() { /usr/bin/osascript - "$@" <<'APPLESCRIPT'
on run argv
  set f to choose folder with prompt (item 1 of argv)
  return POSIX path of f
end run
APPLESCRIPT
}

as_notify() { /usr/bin/osascript - "$@" <<'APPLESCRIPT'
on run argv
  display notification (item 1 of argv) with title (item 2 of argv)
end run
APPLESCRIPT
}

ding(){ /usr/bin/afplay "/System/Library/Sounds/Glass.aiff" >/dev/null 2>&1 || true; }

# ---------------- Welcome ----------------
as_dialog "Welcome to Proxy Love.

• Mirrors MXF audio layout into camera proxies
• Preserves timecode
• Prevents stretch by padding to master DAR (e.g., 4096×2160 → 2048×1080 pillars)

Masters are READ-ONLY. Only Proxies are sanitized."

# Allow Xcode wrapper to pass paths; else use pickers
if [[ -n "${PROXYLOVE_MASTERS:-}" && -n "${PROXYLOVE_PROXIES:-}" ]]; then
  masters="$PROXYLOVE_MASTERS"
  proxies="$PROXYLOVE_PROXIES"
else
  masters="$(as_pick 'Choose your MASTERS (MXF) folder')"
  proxies="$(as_pick 'Choose your PROXIES (MP4) folder')"
fi

outdir="$(dirname "$proxies")/FixedProxies"; mkdir -p "$outdir"
report="$outdir/proxyfix_report.csv"
echo "proxy,master,output,status,notes" > "$report"

# ---------------- Tools ----------------
for t in ffmpeg ffprobe; do
  command -v "$t" >/dev/null 2>&1 || { as_dialog "Missing $t. Install Homebrew (`brew install ffmpeg`) or bundle it."; exit 1; }
done

# ---------------- Helpers ----------------
csv_escape(){ printf '%s' "$1" | sed 's/"/""/g'; }
normalize(){ echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[._-]+//g'; }
kv(){ awk -F= -v k="$1" '$1==k{print $2}'; }
float_abs(){ awk -v x="$1" 'BEGIN{if(x<0)x=-x; printf "%.3f", x}'; }

probe_v(){
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,sample_aspect_ratio \
    -of default=nw=1 "$1"
}
probe_a_lines(){ # channels,layout CSV
  ffprobe -v error -select_streams a -show_entries stream=channels,channel_layout \
    -of csv=p=0:s=, "$1" 2>/dev/null | grep -v '^$' || true
}
extract_tc(){
  ffprobe -v error -select_streams v:0 -show_entries stream=timecode \
    -of default=nw=1:nk=1 "$1" 2>/dev/null || true
}
get_duration(){
  ffprobe -v error -select_streams v:0 -show_entries format=duration \
    -of default=nw=1:nk=1 "$1" 2>/dev/null || echo ""
}

can_use_vtb(){
  [[ "$(uname)" == "Darwin" ]] || return 1
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox
}

encode_vtb_or_x264(){
  # last arg must be output file; everything else is inputs/maps/filters
  local out="${@: -1}"
  local args=( "${@:1:$#-1}" )

  if can_use_vtb; then
    ffmpeg -nostdin -hide_banner -y \
      "${args[@]}" \
      -c:v h264_videotoolbox -b:v 8M -maxrate 12M -bufsize 24M \
      "$out"
  else
    ffmpeg -nostdin -hide_banner -y \
      "${args[@]}" \
      -c:v libx264 -preset veryfast -crf 20 \
      "$out"
  fi
}

# ---------------- Sanitize PROXIES (names only) ----------------
sanitize_one_name(){
  perl -CS -pe 's/\r//g; s/\x{200B}|\x{200C}|\x{200D}|\x{FEFF}//g; s/\x{00A0}/ /g' |
  sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/[[:space:]]+/ /g'
}
sanitize_recursive_proxies(){
  local root="$1"; local renamed=0
  while IFS= read -r -d '' path; do
    local dir base clean target
    dir="$(dirname "$path")"; base="$(basename "$path")"
    clean="$(printf "%s" "$base" | sanitize_one_name)"
    if [[ "$clean" != "$base" ]]; then
      target="$dir/$clean"
      if [[ -e "$target" ]]; then
        suffix=1; ext=""; name="$clean"
        if [[ "$clean" == *.* ]]; then ext=".${clean##*.}"; name="${clean%.*}"; fi
        while [[ -e "$dir/${name}_clean${suffix}${ext}" ]]; do ((suffix++)); done
        target="$dir/${name}_clean${suffix}${ext}"
      fi
      mv "$path" "$target"; ((renamed++))
    fi
  done < <(find "$root" -depth -print0)
  echo "Sanitized $renamed items under Proxies."
}
sanitize_recursive_proxies "$proxies"

# ---------------- Build MASTER index ----------------
master_db="$(mktemp)"
echo "Building master index…"
while IFS= read -r -d '' mxf; do
  stem="$(basename "${mxf%.*}")"
  nstem="$(normalize "$stem")"
  dur="$(get_duration "$mxf")"; [[ -z "$dur" || "$dur" == "N/A" ]] && dur=""
  printf "%s\t%s\t%s\t%s\n" "$nstem" "$stem" "$mxf" "$dur" >> "$master_db"
done < <(find "$masters" -type f \( -iname "*.mxf" -o -iname "*.MXF" \) -print0)

# ---------------- Matcher ----------------
find_master_for_proxy(){
  local proxy_base="$1"   # basename
  local proxy_full="$2"   # full path
  local p_norm; p_norm="$(normalize "${proxy_base%.*}")"

  local best_path="" best_score=0 best_len=0
  local nmaster mstem mpath mdur score

  # exact / prefix / suffix / contains
  while IFS=$'\t' read -r nmaster mstem mpath mdur; do
    score=0
    if   [[ "$p_norm" == "$nmaster" ]]; then score=100
    elif [[ "$p_norm" == "$nmaster"* ]]; then score=90
    elif [[ "$p_norm" == *"$nmaster" ]]; then score=80
    elif [[ "$p_norm" == *"$nmaster"* ]]; then score=70
    fi
    if (( score > best_score )) || { (( score == best_score )) && (( ${#nmaster} > best_len )); }; then
      best_score=$score; best_path="$mpath"; best_len=${#nmaster}
    fi
  done < "$master_db"

  if (( best_score >= 70 )); then echo "$best_path"; return 0; fi

  # duration fallback
  if $ENABLE_DURATION_FALLBACK; then
    local p_dur; p_dur="$(get_duration "$proxy_full")"
    if [[ -n "$p_dur" && "$p_dur" != "N/A" ]]; then
      local best_path_dur="" best_delta="9999" delta
      while IFS=$'\t' read -r nmaster mstem mpath mdur; do
        [[ -z "$mdur" || "$mdur" == "N/A" ]] && continue
        delta="$(float_abs "$(awk -v a="$p_dur" -v b="$mdur" 'BEGIN{print a-b}')")"
        if awk -v d="$delta" 'BEGIN{exit(d<=0.5?0:1)}'; then
          if awk -v d="$delta" -v bd="$best_delta" 'BEGIN{exit(d<bd?0:1)}'; then
            best_delta="$delta"; best_path_dur="$mpath"
          fi
        fi
      done < "$master_db"
      [[ -n "$best_path_dur" ]] && { echo "$best_path_dur"; return 0; }
    fi
  fi
  return 1
}

# ---------------- One proxy ----------------
process_one(){
  local proxy="$1"
  local pname="$(basename "$proxy")"

  as_notify "$pname — matching…" "Proxy Love"

  local master; master="$(find_master_for_proxy "$pname" "$proxy" || true)"
  if [[ -z "${master:-}" ]]; then
    echo "\"$(csv_escape "$proxy")\",\"\",\"\",\"SKIPPED\",\"no master match\"" >> "$report"
    return 0
  fi

  local m_stem; m_stem="$(basename "${master%.*}")"
  local out_name="$pname"; $RENAME_TO_MASTER && out_name="${m_stem}.MP4"
  local out="$outdir/$out_name"
  local tmp="${out}.tmp.$$.${RANDOM}.mp4"
  cleanup(){ rm -f "$tmp" 2>/dev/null || true; }
  trap cleanup RETURN

  local tc; tc="$(extract_tc "$proxy" || true)"

  # Audio layout from MXF
  local ap=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && ap+=("$line")
  done < <(probe_a_lines "$master")
  if [[ ${#ap[@]} -eq 0 ]]; then
    echo "\"$(csv_escape "$proxy")\",\"$(csv_escape "$master")\",\"\",\"SKIPPED\",\"no audio in MXF\"" >> "$report"
    return 0
  fi

  # DAR logic
  local mvinfo pvinfo mw mh pw ph msar psar mDAR pDAR
  mvinfo="$(probe_v "$master")"; pvinfo="$(probe_v "$proxy")"
  mw="$(kv width  <<<"$mvinfo")"; mh="$(kv height <<<"$mvinfo")"
  pw="$(kv width  <<<"$pvinfo")"; ph="$(kv height <<<"$pvinfo")"
  msar="$(kv sample_aspect_ratio <<<"$mvinfo")"; psar="$(kv sample_aspect_ratio <<<"$pvinfo")"
  [[ -z "$msar" || "$msar" == "N/A" || "$msar" == "0:1" ]] && msar="1:1"
  [[ -z "$psar" || "$psar" == "N/A" || "$psar" == "0:1" ]] && psar="1:1"
  mDAR=$(awk -v W="$mw" -v H="$mh" -v S="$msar" 'BEGIN{split(S,a,":"); print (W*a[1])/(H*a[2])}')
  pDAR=$(awk -v W="$pw" -v H="$ph" -v S="$psar" 'BEGIN{split(S,a,":"); print (W*a[1])/(H*a[2])}')

  local v_args=() note="video copied"
  if awk -v A="$mDAR" -v B="$pDAR" 'BEGIN{d=A-B; if (d<0) d=-d; exit(d>0.001?0:1)}'; then
    if awk 'BEGIN{exit(ARGV[1]>ARGV[2]?0:1)}' "$mDAR" "$pDAR"; then
      # master wider → pillarbox width (e.g., 4096/2160*1080=2048)
      local targetW xoff
      targetW=$(awk -v dar="$mDAR" -v h="$ph" 'BEGIN{w=dar*h; w=int(w/2)*2; if(w<2)w=2; print w}')
      xoff=$(awk -v W="$targetW" -v w="$pw" 'BEGIN{print int((W-w)/2)}')
      v_args=(-vf "setsar=1:1,pad=${targetW}:${ph}:${xoff}:0:color=${PILLAR_COLOR}")
      note="pillarboxed ${pw}x${ph}→${targetW}x${ph}"
    else
      local targetH yoff
      targetH=$(awk -v dar="$mDAR" -v w="$pw" 'BEGIN{h=w/dar; h=int(h/2)*2; if(h<2)h=2; print h}')
      yoff=$(awk -v H="$targetH" -v h="$ph" 'BEGIN{print int((H-h)/2)}')
      v_args=(-vf "setsar=1:1,pad=${pw}:${targetH}:0:${yoff}:color=${PILLAR_COLOR}")
      note="letterboxed ${pw}x${ph}→${pw}x${targetH}"
    fi
  else
    v_args=(-c:v copy)
  fi

  local base_in=(-i "$proxy" -i "$master" -map 0:v:0)

  # Build audio maps/labels
  local a_map=() a_meta=()
  if [[ ${#ap[@]} -gt 1 ]]; then
    local i=0
    for ent in "${ap[@]}"; do
      IFS=',' read -r ch layout <<<"$ent"
      a_map+=(-map "1:a:$i")
      local ttl="Mono $((i+1))"; [[ "${ch:-1}" -gt 1 ]] && ttl="Stereo $((i+1))"
      a_meta+=(-metadata:s:a:$i title="$ttl")
      ((i++))
    done
  else
    IFS=',' read -r ch layout <<<"${ap[0]}"
  fi

  # ---------- Encode with error checks (FFmpeg never reads stdin) ----------
  set +e
  if [[ ${#ap[@]} -gt 1 ]]; then
    if [[ "${v_args[0]}" == "-c:v copy" ]]; then
      ffmpeg -nostdin -hide_banner -y "${base_in[@]}" "${v_args[@]}" \
        "${a_map[@]}" -c:a aac -ar 48000 \
        "${a_meta[@]}" -movflags +use_metadata_tags ${tc:+-timecode "$tc"} \
        "$tmp"
    else
      encode_vtb_or_x264 "${base_in[@]}" "${v_args[@]}" \
        "${a_map[@]}" -c:a aac -ar 48000 \
        "${a_meta[@]}" -movflags +use_metadata_tags ${tc:+-timecode "$tc"} \
        "$tmp"
    fi
  else
    if [[ "${v_args[0]}" == "-c:v copy" ]]; then
      ffmpeg -nostdin -hide_banner -y "${base_in[@]}" "${v_args[@]}" \
        -map 1:a:0 -c:a aac -ar 48000 -ac "${ch:-1}" \
        $( [[ -n "${layout:-}" && "$layout" != "unknown" ]] && printf -- '-channel_layout %s' "$layout" ) \
        -metadata:s:a:0 title="MXF Audio (${ch:-1} ch)" \
        -movflags +use_metadata_tags ${tc:+-timecode "$tc"} \
        "$tmp"
    else
      encode_vtb_or_x264 "${base_in[@]}" "${v_args[@]}" \
        -map 1:a:0 -c:a aac -ar 48000 -ac "${ch:-1}" \
        $( [[ -n "${layout:-}" && "$layout" != "unknown" ]] && printf -- '-channel_layout %s' "$layout" ) \
        -metadata:s:a:0 title="MXF Audio (${ch:-1} ch)" \
        -movflags +use_metadata_tags ${tc:+-timecode "$tc"} \
        "$tmp"
    fi
  fi
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "\"$(csv_escape "$proxy")\",\"$(csv_escape "$master")\",\"\",\"ERROR\",\"ffmpeg failed (rc=$rc)\"" >> "$report"
    return 0
  fi
  if [[ ! -f "$tmp" ]] || [[ $(stat -f%z "$tmp" 2>/dev/null || echo 0) -lt 1000 ]]; then
    echo "\"$(csv_escape "$proxy")\",\"$(csv_escape "$master")\",\"\",\"ERROR\",\"output invalid\"" >> "$report"
    return 0
  fi

  mv -f "$tmp" "$out"
  echo "\"$(csv_escape "$proxy")\",\"$(csv_escape "$master")\",\"$(csv_escape "$out")\",\"OK\",\"$note\"" >> "$report"
  return 0
}

# ---------------- Main: process ALL proxies ----------------
proxy_count=0
while IFS= read -r -d '' proxy; do
  ((proxy_count++))
  echo "Processing proxy #$proxy_count: $(basename "$proxy")"
  process_one "$proxy" </dev/null
  echo "Finished processing proxy #$proxy_count"
done < <(find "$proxies" -type f \( -iname "*.mp4" -o -iname "*.MP4" \) -print0)

# Summarize directly from CSV, stripping quotes around the status field
rows=$(( $(wc -l < "$report") - 1 ))   # data rows (minus header)
ok=$(awk -F, 'NR>1{ s=$4; gsub(/^ *"|" *$/,"",s); if (s=="OK") c++ } END{print c+0}' "$report")
skipped=$(( rows - ok ))
total=$rows

echo "Total: $total  OK: $ok  Skipped: $skipped"
echo "Outputs → $outdir"
echo "Report  → $report"

ding
as_dialog "Proxy Love finished.

Processed: $total
OK:        $ok
Skipped:   $skipped

Output folder:
$outdir

Report:
$report"

open "$outdir" 2>/dev/null || true
exit 0
