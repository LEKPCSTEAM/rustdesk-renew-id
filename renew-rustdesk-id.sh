#!/usr/bin/env bash
# รีเซ็ต RustDesk ID ใหม่ (สุ่ม ID ใหม่ลง RustDesk.toml + สร้าง key pair ใหม่, รหัสผ่านถาวรเดิมยังใช้ได้)
# ติดตั้งเป็นไอคอนในรายการ app : bash renew-rustdesk-id.sh --install   (sudo = ติดตั้งให้ทุก user)
# ถอนการติดตั้ง               : bash renew-rustdesk-id.sh --uninstall
# ใช้ผ่าน terminal / SSH        : sudo rustdesk-renew-id --cli
set -euo pipefail

APP_ID="rustdesk-renew-id"
APP_NAME="Renew RustDesk ID"
ROOT_HOME="/root"
HOMES_DIR="/home"
BACKUP_ROOT="/var/backups/rustdesk-renew-id"
LOG_FILE="/var/log/rustdesk-renew-id.log"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# ---------- ส่วนที่รันเป็น root ----------

# GUI mode ส่งบรรทัดให้ zenity --progress, CLI mode พิมพ์ข้อความปกติ
OUT_MODE="cli"
step() {
  if [[ "$OUT_MODE" == "gui" ]]; then
    printf '%s\n# %s\n' "$1" "$2"
  else
    printf '[%3s%%] %s\n' "$1" "$2"
  fi
}

need_root() {
  (( EUID == 0 )) && return 0
  echo "ERROR=ต้องรันด้วยสิทธิ์ root"; return 1
}

clean_id() {
  local id
  id="$(tail -n1 | tr -d '[:space:]')"
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ && "$id" != "0" ]] && echo "$id"
  return 0
}

get_id() { timeout 5 rustdesk --get-id 2>/dev/null | clean_id; }

# อ่าน ID ในมุมของ user ที่กดโปรแกรม (ตอน login อยู่ RustDesk --server รันเป็น user นั้น)
user_get_id() {
  local uid="${1:-}" user home
  if [[ -n "$uid" && "$uid" != "0" ]] && user="$(id -nu "$uid" 2>/dev/null)"; then
    home="$(getent passwd "$user" | cut -d: -f6)"
    runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" \
      timeout 5 rustdesk --get-id 2>/dev/null | clean_id
  else
    get_id
  fi
}

stop_rustdesk() {
  systemctl stop rustdesk 2>/dev/null || true
  pkill -x rustdesk 2>/dev/null || true
  for _ in $(seq 1 10); do
    pgrep -x rustdesk >/dev/null || return 0
    sleep 1
  done
  pkill -9 -x rustdesk 2>/dev/null || true
  sleep 1
}

# ใส่ id ใหม่แบบ plain text (RustDesk จะเข้ารหัสเป็น enc_id เองตอนเปิด)
# และลบ key_pair / key_confirmed / keys_confirmed ให้สร้างและลงทะเบียนกับ server ใหม่
rewrite_toml() {
  local file="$1" new_id="$2" tmp
  tmp="$(mktemp)"
  {
    printf "id = '%s'\n" "$new_id"
    awk '
      skip_kp { depth += gsub(/\[/, "[") - gsub(/\]/, "]"); if (depth <= 0) skip_kp = 0; next }
      /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { in_kc = ($0 ~ /^[[:space:]]*\[keys_confirmed\]/) }
      in_kc { next }
      /^(id|enc_id|key_confirmed|keys_confirmed)[[:space:]]*=/ { next }
      /^key_pair[[:space:]]*=/ { depth = gsub(/\[/, "[") - gsub(/\]/, "]"); if (depth > 0) skip_kp = 1; next }
      { print }
    ' "$file"
  } >"$tmp"
  if command -v python3 >/dev/null &&
     ! python3 -I -c 'import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
sys.exit(0 if d.get("id") == sys.argv[2] and "enc_id" not in d and "key_pair" not in d else 1)' "$tmp" "$new_id" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  # เขียนทับเนื้อไฟล์เดิม เจ้าของและสิทธิ์ไฟล์จะคงเดิม
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

do_reset() {
  OUT_MODE="${1:-cli}"
  # uid ของคนที่สั่ง (pkexec / sudo ตั้งให้)
  local target_uid="${PKEXEC_UID:-${SUDO_UID:-}}"
  local old_id new_id rand_id ts backup f src home root_conf files=()

  need_root || return 1
  if ! command -v rustdesk >/dev/null; then
    echo "ERROR=ไม่พบโปรแกรม RustDesk ในเครื่อง"; return 1
  fi
  if ! systemctl cat rustdesk >/dev/null 2>&1; then
    echo "ERROR=ไม่พบ rustdesk.service (รองรับเฉพาะ RustDesk ที่ติดตั้งแบบ .deb / .rpm)"; return 1
  fi

  step 5 "อ่าน ID เดิม..."
  old_id="$(user_get_id "$target_uid")"

  root_conf="$ROOT_HOME/.config/rustdesk/RustDesk.toml"
  for f in "$root_conf" "$HOMES_DIR"/*/.config/rustdesk/RustDesk.toml; do
    [[ -f "$f" ]] && files+=("$f")
  done
  if (( ${#files[@]} == 0 )); then
    echo "ERROR=ไม่พบไฟล์ตั้งค่า RustDesk.toml (ลองเปิด RustDesk สักครั้งก่อน)"; return 1
  fi

  step 15 "สำรองไฟล์ตั้งค่าเดิม..."
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/$ts"
  install -d -m 0700 "$backup"
  # เก็บตาม path เดิม แต่คืนค่าทีละไฟล์เท่านั้น (cp -a ทั้ง tree จะเอาสิทธิ์โฟลเดอร์สำรองไปทับ / /home /root)
  for f in "${files[@]}"; do
    install -d -m 0700 "$backup$(dirname "$f")"
    cp -a "$f" "$backup$f"
  done
  {
    echo '#!/usr/bin/env bash'
    echo '# คืนค่า RustDesk.toml ก่อนรีเซ็ต ID: sudo bash restore.sh'
    echo 'set -e'
    echo 'systemctl stop rustdesk || true'
    echo 'pkill -x rustdesk || true'
    echo 'sleep 2'
    for f in "${files[@]}"; do printf 'cp -a %q %q\n' "$backup$f" "$f"; done
    echo 'systemctl start rustdesk'
    echo 'echo "คืนค่าแล้ว"'
  } >"$backup/restore.sh"
  chmod 0700 "$backup/restore.sh"

  step 30 "หยุด RustDesk service..."
  stop_rustdesk

  step 45 "เขียน ID ใหม่..."
  rand_id="$(shuf -i 1000000000-1999999999 -n 1)"
  for f in "${files[@]}"; do
    if ! rewrite_toml "$f" "$rand_id"; then
      for src in "${files[@]}"; do cp -a "$backup$src" "$src" || true; done
      systemctl start rustdesk || true
      echo "ERROR=แก้ไฟล์ $f ไม่สำเร็จ คืนค่าเดิมให้แล้ว"; return 1
    fi
  done
  # ตอนเริ่ม --server ของ user จะดึง config จาก root มาทับ ถ้า root ไม่มีไฟล์จะได้ ID เดิม (จาก MAC) กลับมา
  if [[ ! -f "$root_conf" ]]; then
    src="${files[0]}"
    if [[ -n "$target_uid" && "$target_uid" != "0" ]]; then
      home="$(getent passwd "$target_uid" | cut -d: -f6)"
      [[ -f "$home/.config/rustdesk/RustDesk.toml" ]] && src="$home/.config/rustdesk/RustDesk.toml"
    fi
    install -D -m 0600 -o root -g root "$src" "$root_conf"
  fi

  step 55 "เปิด RustDesk service ใหม่..."
  systemctl start rustdesk

  # รอให้ลงทะเบียนกับ server ก่อน ถ้า ID ชนกับเครื่องอื่น RustDesk จะสุ่มให้ใหม่เอง
  step 65 "รอ RustDesk ลงทะเบียน ID ใหม่กับ server..."
  new_id=""
  for i in $(seq 1 40); do
    sleep 1
    (( i < 10 )) && continue
    new_id="$(user_get_id "$target_uid")"
    [[ -n "$new_id" ]] && break
  done
  if [[ -z "$new_id" ]]; then
    echo "$(date '+%F %T') FAIL old=${old_id:-?} backup=$backup" >>"$LOG_FILE"
    echo "ERROR=อ่าน ID ใหม่ไม่ได้ ลองเปิด RustDesk ดู ID เอง ไฟล์เดิมสำรองไว้ที่ $backup"
    return 1
  fi

  echo "$(date '+%F %T') OK old=${old_id:-?} new=$new_id backup=$backup" >>"$LOG_FILE"
  echo "OLDID=${old_id:-}"
  echo "NEWID=$new_id"
  echo "BACKUP=$backup"
  step 100 "เสร็จสิ้น"
}

# ---------- ติดตั้ง / ถอนการติดตั้ง ----------

paths() {
  if (( EUID == 0 )); then
    BIN_PATH="/usr/local/bin/$APP_ID"
    DESKTOP_PATH="/usr/share/applications/$APP_ID.desktop"
  else
    BIN_PATH="$HOME/.local/bin/$APP_ID"
    DESKTOP_PATH="$HOME/.local/share/applications/$APP_ID.desktop"
  fi
}

do_install() {
  paths
  install -D -m 0755 "$SELF" "$BIN_PATH"
  install -d "$(dirname "$DESKTOP_PATH")"
  cat >"$DESKTOP_PATH" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Name[th]=รีเซ็ต RustDesk ID ใหม่
GenericName=RustDesk ID Reset
Comment=Reset this computer's RustDesk ID to a new one
Comment[th]=สุ่ม RustDesk ID ใหม่ให้เครื่องนี้
Exec=$BIN_PATH
Icon=rustdesk
Terminal=false
Categories=Network;RemoteAccess;
Keywords=rustdesk;id;reset;renew;remote;
StartupNotify=true
EOF
  chmod 0644 "$DESKTOP_PATH"
  update-desktop-database "$(dirname "$DESKTOP_PATH")" 2>/dev/null || true
  echo "ติดตั้งแล้ว:"
  echo "  โปรแกรม : $BIN_PATH"
  echo "  ไอคอน   : $DESKTOP_PATH"
  echo "เปิดได้จากรายการ app โดยค้นหา \"RustDesk\" หรือ \"$APP_NAME\""

  local cmd missing=()
  for cmd in rustdesk zenity pkexec; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    echo "คำเตือน: ยังไม่มี ${missing[*]} ในเครื่อง"
    echo "  RustDesk ติดตั้งจาก https://github.com/rustdesk/rustdesk/releases (.deb)"
    echo "  ที่เหลือ: sudo apt install zenity pkexec xclip"
  fi
}

do_uninstall() {
  paths
  rm -f "$BIN_PATH" "$DESKTOP_PATH"
  update-desktop-database "$(dirname "$DESKTOP_PATH")" 2>/dev/null || true
  echo "ถอนการติดตั้งแล้ว"
}

# ---------- หน้าต่าง GUI (รันเป็น user ปกติ) ----------

zerr() { zenity --error --title="$APP_NAME" --width=420 --text="$1" 2>/dev/null || true; }

run_gui() {
  local old_id out rc new_id backup err

  if ! command -v rustdesk >/dev/null; then
    zerr "ไม่พบโปรแกรม RustDesk ในเครื่องนี้"; exit 1
  fi
  old_id="$(get_id)"

  zenity --question --title="$APP_NAME" --width=460 \
    --icon=rustdesk --ok-label="รีเซ็ต ID" --cancel-label="ยกเลิก" \
    --text="<big><b>รีเซ็ต RustDesk ID ใหม่</b></big>

ID ปัจจุบัน: <b>${old_id:-ไม่ทราบ}</b>

• ทุกคนที่กำลัง remote เข้าเครื่องนี้ผ่าน RustDesk <b>จะหลุดทันที</b>
• ต้องใช้ ID ใหม่ในการเชื่อมต่อครั้งต่อไป
• รหัสผ่านถาวร (Permanent Password) เดิมยังใช้ได้
• ไฟล์ตั้งค่าเดิมจะสำรองไว้ที่ $BACKUP_ROOT

ต้องการดำเนินการต่อหรือไม่?" 2>/dev/null || exit 0

  # pkexec จะเด้งหน้าต่างขอรหัส admin ของเครื่อง แล้วรันส่วน reset เป็น root
  out="$(mktemp)"
  trap "rm -f -- '$out'" EXIT
  set +e
  pkexec "$SELF" --reset gui </dev/null 2>/dev/null | tee "$out" |
    zenity --progress --title="$APP_NAME" --width=420 --text="กำลังเริ่ม..." \
      --percentage=0 --auto-close --no-cancel 2>/dev/null
  rc=${PIPESTATUS[0]}
  set -e

  if (( rc == 126 || rc == 127 )) && [[ ! -s "$out" ]]; then
    zerr "ยกเลิก หรือใส่รหัส admin ไม่ถูกต้อง — ยังไม่มีการเปลี่ยนแปลงใด ๆ"; exit 1
  fi
  err="$(sed -n 's/^ERROR=//p' "$out")"
  new_id="$(sed -n 's/^NEWID=//p' "$out")"
  backup="$(sed -n 's/^BACKUP=//p' "$out")"
  if [[ -n "$err" || -z "$new_id" ]]; then
    zerr "รีเซ็ตไม่สำเร็จ
${err:-ไม่ทราบสาเหตุ (exit $rc)}"; exit 1
  fi

  local note=""
  [[ "$new_id" == "$old_id" ]] && note="

⚠ ได้ ID เดิมกลับมา — ลองรันอีกครั้ง"

  notify-send -i rustdesk "$APP_NAME" "RustDesk ID ใหม่: $new_id" 2>/dev/null || true

  # ปุ่ม extra จะพิมพ์ชื่อปุ่มออก stdout แล้ว exit 1
  local copy_label="คัดลอก ID" choice
  choice="$(zenity --info --title="$APP_NAME" --width=420 --icon=rustdesk \
    --ok-label="ปิด" --extra-button="$copy_label" \
    --text="<big>RustDesk ID ใหม่</big>

<span size='xx-large' weight='bold'>$new_id</span>

ID เดิม: ${old_id:-ไม่ทราบ}
สำรองไฟล์เดิมไว้ที่: $backup$note" 2>/dev/null || true)"
  [[ "$choice" == "$copy_label" ]] && copy_text "$new_id"
  return 0
}

copy_text() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null; then
    printf '%s' "$1" | wl-copy
  elif command -v xclip >/dev/null; then
    printf '%s' "$1" | xclip -selection clipboard
  elif command -v xsel >/dev/null; then
    printf '%s' "$1" | xsel --clipboard --input
  else
    return 0
  fi
  notify-send -i rustdesk "$APP_NAME" "คัดลอก ID $1 แล้ว" 2>/dev/null || true
}

# ---------- โหมด terminal ----------

run_cli() {
  if (( EUID != 0 )); then
    exec sudo "$SELF" --cli
  fi
  local ans
  echo "RustDesk ID ปัจจุบัน: $(user_get_id "${SUDO_UID:-}")"
  echo "คำเตือน: คนที่ remote เข้าเครื่องนี้ผ่าน RustDesk จะหลุด (รหัสผ่านถาวรเดิมยังใช้ได้)"
  read -rp "พิมพ์ yes เพื่อรีเซ็ต ID: " ans
  [[ "$ans" == "yes" ]] || { echo "ยกเลิก"; exit 0; }
  do_reset cli | sed -e 's/^NEWID=/RustDesk ID ใหม่ : /' -e 's/^OLDID=/RustDesk ID เดิม : /' \
    -e 's/^BACKUP=/สำรองไฟล์เดิม   : /' -e 's/^ERROR=/ผิดพลาด: /'
}

# source ไฟล์นี้เพื่อทดสอบฟังก์ชันได้โดยไม่รันคำสั่ง
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

case "${1:-}" in
  --reset)
    # ปิดหน้าต่าง progress เสมอ แม้ reset ล้มกลางทาง
    [[ "${2:-}" == "gui" ]] && trap 'echo 100' EXIT
    do_reset "${2:-cli}" ;;
  --install)   do_install ;;
  --uninstall) do_uninstall ;;
  --cli)       run_cli ;;
  -h|--help)   sed -n '2,5p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  "")
    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && (( EUID != 0 )) && command -v zenity >/dev/null; then
      run_gui
    else
      run_cli
    fi ;;
  *) echo "ไม่รู้จักตัวเลือก: $1 (ดู --help)"; exit 2 ;;
esac
