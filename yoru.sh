#!/bin/bash

# ================= COLOR =================
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
white='\033[0m'

# ================= VARIANT =================
# Tanpa argumen  -> build KSU lalu NonKSU (1 job, berurutan)
# Argumen KSU / NonKSU -> build satu varian saja
VARIANT_ARG=$1
if [ -z "$VARIANT_ARG" ]; then
    VARIANT_ARG="ALL"
fi
case "$VARIANT_ARG" in
    ALL|all) VARIANTS=(KSU NonKSU) ;;
    *)       VARIANTS=("$VARIANT_ARG") ;;
esac

# ================= PATH =================
DEFCONFIG="msm8953-perf_defconfig"
FRAGMENT="mi8953.config"
TEMP_DEFCONFIG="msm8953-perf_temp_defconfig"
ROOTDIR=$(pwd)
OUTDIR="$ROOTDIR/out/arch/arm64/boot"
ANYKERNEL_DIR="$ROOTDIR/AnyKernel"
LOG_DIR="$ROOTDIR/logs"
ZIPS_DIR="$ROOTDIR/zips"
IMAGES_DIR="$ROOTDIR/images"
KIMG_DTB="$OUTDIR/Image.gz-dtb"
KIMG="$OUTDIR/Image.gz"

# ========== TOOLCHAIN (CLANG) ===========
export PATH="$ROOTDIR/clang-zyc/bin:$PATH"

# ================= INFO =================
KERNEL_NAME="Yoru"
DEVICE="mi8953"

# =============== DATE (WIB) ===============
DATE_TITLE=$(TZ=Asia/Jakarta date +"%d%m%Y")
TIME_TITLE=$(TZ=Asia/Jakarta date +"%H%M%S")
BUILD_DATETIME=$(TZ=Asia/Jakarta date +"%d %B %Y")

# ================= API & TELEGRAM =================
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
export PIXELDRAIN_API_KEY="${PIXELDRAIN_API_KEY}"
export TELE_API_ID="${TELE_API_ID}"
export TELE_API_HASH="${TELE_API_HASH}"
export TELE_SESSION="${TELE_SESSION}"

# Interval update pesan Telegram (detik). Aman untuk limit grup (<20 edit/menit)
TG_INTERVAL="${TG_INTERVAL:-5}"
# 1 = kirim juga file zip / log sebagai pesan terpisah (default 0 = cukup 1 pesan)
SEND_FILES="${SEND_FILES:-0}"
# Perkiraan jumlah object compile (dikalibrasi otomatis setelah build pertama selesai)
EST_OBJECTS="${EST_OBJECTS:-2200}"
OBJ_REGEX='^[[:space:]]+(CC|AS|HOSTCC)[[:space:]]'

# ================= GLOBAL =================
BUILD_TIME="unknown"
KERNEL_VERSION="unknown"
IMG_USED="unknown"
ZIP_NAME=""
VARIANT=""
LOG=""
MSG_ID=""
UPDATER_PID=""
START=$(date +%s)
NL=$'\n'
STATE_DIR=$(mktemp -d)

# ================= STATE (dibaca oleh updater realtime) =================
st_set() { printf '%s' "$2" > "$STATE_DIR/$1"; }
st_get() { local v; v=$(cat "$STATE_DIR/$1" 2>/dev/null); echo "${v:-$2}"; }

fmt_time() {
    local s=$1
    if [ "$s" -ge 3600 ]; then
        printf '%d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
    else
        printf '%02d:%02d' $((s / 60)) $((s % 60))
    fi
}

make_bar() {
    local p=$1 f i s=""
    f=$((p / 10))
    for ((i = 0; i < 10; i++)); do
        if ((i < f)); then s+="█"; else s+="░"; fi
    done
    echo "$s"
}

# ================= FUNCTION =================
clone_anykernel() {
    if [ ! -d "$ANYKERNEL_DIR" ]; then
        echo -e "$yellow[+] Cloning AnyKernel3...$white"
        git clone -b ${DEVICE} https://github.com/rahmatsobrian/AnyKernel3.git "$ANYKERNEL_DIR" || exit 1
    fi
}

get_kernel_version() {
    if [ -f "Makefile" ]; then
        VERSION=$(grep -E '^VERSION =' Makefile | awk '{print $3}')
        PATCHLEVEL=$(grep -E '^PATCHLEVEL =' Makefile | awk '{print $3}')
        SUBLEVEL=$(grep -E '^SUBLEVEL =' Makefile | awk '{print $3}')
        KERNEL_VERSION="${VERSION}.${PATCHLEVEL}.${SUBLEVEL}"
    else
        KERNEL_VERSION="unknown"
    fi
}

# ================= TELEGRAM (1 PESAN, DI-EDIT REALTIME) =================
render_variant() {
    local V=$1 now=$2
    local status start end el cnt total pct pd sl bt err stage label
    status=$(st_get "$V.status" waiting)
    start=$(st_get "$V.start" "$now")
    end=$(st_get "$V.end" "$now")

    case "$status" in
        waiting)
            printf '⏳ <b>%s</b> — Waiting' "$V"
            ;;
        config|building|packing|uploading)
            el=$((now - start))
            case "$status" in
                config)    label="⚙️ Configuring" ;;
                building)  label="🔨 Compiling" ;;
                packing)   label="📦 Packing" ;;
                uploading) label="☁️ Uploading" ;;
            esac
            if [ "$status" = "building" ]; then
                cnt=$(grep -cE "$OBJ_REGEX" "$LOG_DIR/build-${V}.txt" 2>/dev/null)
                cnt=${cnt:-0}
                total=$(st_get total "$EST_OBJECTS")
                [ "$total" -gt 0 ] 2>/dev/null || total=2200
                pct=$((cnt * 100 / total))
                [ "$pct" -gt 99 ] && pct=99
                printf '<b>%s</b> — %s\n<code>%s %d%%</code> (%d obj)\n⏱ %s' \
                    "$V" "$label" "$(make_bar "$pct")" "$pct" "$cnt" "$(fmt_time "$el")"
            else
                printf '<b>%s</b> — %s\n⏱ %s' "$V" "$label" "$(fmt_time "$el")"
            fi
            ;;
        "done")
            bt=$(st_get "$V.bt" 0)
            pd=$(st_get "$V.pd" "")
            sl=$(st_get "$V.sl" "")
            printf '✅ <b>%s</b> — Done\n⏱ Build %s · Total %s\n' "$V" "$(fmt_time "$bt")" "$(fmt_time $((end - start)))"
            if [[ "$pd" == http* ]]; then
                printf '🔗 <a href="%s">Direct Download (Pixeldrain)</a>\n' "$pd"
            else
                printf '⚠️ Pixeldrain: Upload Failed\n'
            fi
            if [[ "$sl" == http* ]]; then
                printf '💰 <a href="%s">Support via Safelinku</a>' "$sl"
            else
                printf '⚠️ Safelinku: Generation Failed'
            fi
            ;;
        failed)
            stage=$(st_get "$V.failstage" unknown)
            err=$(st_get "$V.err" "")
            printf '❌ <b>%s</b> — Failed at %s\n⏱ %s' "$V" "$stage" "$(fmt_time $((end - start)))"
            if [ -n "$err" ]; then
                printf '\n<pre>%s</pre>' "$err"
            fi
            ;;
    esac
}

render_msg() {
    local now=$1 final title out V
    final=$(st_get final "")
    if [ -n "$final" ]; then
        now=$(st_get end_all "$now")
    fi

    case "$final" in
        success) title="🔥 <b>${KERNEL_NAME} Kernel CI — Success</b>" ;;
        partial) title="⚠️ <b>${KERNEL_NAME} Kernel CI — Partially Failed</b>" ;;
        failed)  title="❌ <b>${KERNEL_NAME} Kernel CI — Failed</b>" ;;
        *)       title="🚀 <b>${KERNEL_NAME} Kernel CI — Running</b>" ;;
    esac

    out="${title}${NL}${NL}"
    out+="📱 <b>Device</b> : ${DEVICE}${NL}"
    out+="🍃 <b>Kernel</b> : ${KERNEL_NAME} ${KERNEL_VERSION}${NL}"
    out+="🕒 <b>Date</b> : ${BUILD_DATETIME}${NL}${NL}"

    for V in "${VARIANTS[@]}"; do
        out+="$(render_variant "$V" "$now")${NL}${NL}"
    done

    out+="⏱ <b>Total</b> : $(fmt_time $((now - START)))${NL}"
    out+="🔄 <b>Updated</b> : $(TZ=Asia/Jakarta date +%H:%M:%S) WIB"

    if [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_REPOSITORY" ]; then
        out+="${NL}📎 <a href=\"${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}\">View Workflow Run</a>"
    fi

    printf '%s' "$out"
}

tg_start() {
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        echo -e "$yellow[!] Telegram token/chat id kosong, notifikasi dilewati$white"
        return
    fi
    local resp
    resp=$(curl -s --max-time 15 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode=HTML \
        -d disable_web_page_preview=true \
        --data-urlencode text="$(render_msg "$(date +%s)")")
    MSG_ID=$(echo "$resp" | jq -r '.result.message_id // empty')
}

tg_edit() {
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$MSG_ID" ]; then
        return
    fi
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText" \
        -d chat_id="${TG_CHAT_ID}" \
        -d message_id="${MSG_ID}" \
        -d parse_mode=HTML \
        -d disable_web_page_preview=true \
        --data-urlencode text="$1" > /dev/null
}

# Loop di background: edit pesan tiap TG_INTERVAL detik, waktu dihitung dari jam sistem
tg_updater() {
    local tick=0
    while [ ! -f "$STATE_DIR/stop" ]; do
        sleep 1
        [ -f "$STATE_DIR/stop" ] && break
        tick=$((tick + 1))
        if [ $((tick % TG_INTERVAL)) -eq 0 ]; then
            tg_edit "$(render_msg "$(date +%s)")"
        fi
    done
}

send_telegram_log() {
    LOG_FILE="$LOG_DIR/build-${VARIANT}.txt"
    [ ! -f "$LOG_FILE" ] && return
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"${LOG_FILE}"
}

# Jalankan perintah, tampil di console + simpan ke log varian (untuk hitung progress)
run_logged() {
    "$@" 2>&1 | tee -a "$LOG"
    return ${PIPESTATUS[0]}
}

fail_variant() {
    local stage err
    stage=$(st_get "$VARIANT.status" unknown)
    st_set "$VARIANT.failstage" "$stage"
    st_set "$VARIANT.end" "$(date +%s)"

    err=$(grep -iE 'error|\*\*\*|undefined reference' "$LOG" 2>/dev/null | tail -n 6)
    [ -z "$err" ] && err=$(tail -n 6 "$LOG" 2>/dev/null)
    err=$(printf '%s' "$err" | cut -c1-150 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    st_set "$VARIANT.err" "$err"
    st_set "$VARIANT.status" failed

    echo -e "$red[✗] ${VARIANT} failed at ${stage}$white"
    if [ "$SEND_FILES" = "1" ]; then
        send_telegram_log
    fi
}

# ================= Build Kernel =================
build_kernel() {
    st_set "$VARIANT.start" "$(date +%s)"
    st_set "$VARIANT.status" config

    echo -e "$yellow[+] Removing out folder...$white"
    rm -rf out

    echo -e "$yellow[+] Creating out folder...$white"
    mkdir -p out

    # === DYNAMIC DEFCONFIG SETUP ===
    echo -e "$yellow[+] Preparing kernel config for ${VARIANT}...$white"
    cp arch/arm64/configs/${DEFCONFIG} arch/arm64/configs/${TEMP_DEFCONFIG}

    if [ "$VARIANT" == "NonKSU" ]; then
        echo -e "$yellow[+] Stripping KSU configs for Non-KSU build...$white"
        sed -i 's/CONFIG_KSU=y/# CONFIG_KSU is not set/g' arch/arm64/configs/${TEMP_DEFCONFIG}
    fi

    # Setting config
    echo -e "$yellow[+] Preparing kernel config...$white"
    run_logged make O=out ARCH=arm64 ${TEMP_DEFCONFIG} ${FRAGMENT} || {
        rm -f arch/arm64/configs/${TEMP_DEFCONFIG}
        fail_variant
        return 1
    }
    rm -f arch/arm64/configs/${TEMP_DEFCONFIG}

    BUILD_START=$(TZ=Asia/Jakarta date +%s)
    st_set "$VARIANT.status" building

    echo -e "$yellow[+] Building Kernel [${VARIANT}]...$white"
    run_logged make -j$(nproc --all) \
        ARCH=arm64 \
        O=out \
        CC=clang \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_ARM32=arm-linux-gnueabi- || {
            fail_variant
            return 1
        }

    BUILD_END=$(TZ=Asia/Jakarta date +%s)
    DIFF=$((BUILD_END - BUILD_START))
    BUILD_TIME="$((DIFF / 60)) min $((DIFF % 60)) sec"
    st_set "$VARIANT.bt" "$DIFF"

    # Kalibrasi total object untuk varian berikutnya
    local cnt
    cnt=$(grep -cE "$OBJ_REGEX" "$LOG" 2>/dev/null)
    cnt=${cnt:-0}
    if [ "$cnt" -gt 500 ]; then
        st_set total "$cnt"
    fi

    # Simpan image per varian (folder out dihapus saat build varian berikutnya)
    mkdir -p "$IMAGES_DIR/$VARIANT"
    cp "$KIMG_DTB" "$IMAGES_DIR/$VARIANT/" 2>/dev/null
    cp "$KIMG" "$IMAGES_DIR/$VARIANT/" 2>/dev/null

    ZIP_NAME="${KERNEL_NAME}-${VARIANT}-${DEVICE}-${KERNEL_VERSION}-${DATE_TITLE}-${TIME_TITLE}.zip"
}

# =============== Zipping Kernel ===============
pack_kernel() {
    st_set "$VARIANT.status" packing
    echo -e "$yellow[+] Packing AnyKernel...$white"

    clone_anykernel
    cd "$ANYKERNEL_DIR" || exit 1

    rm -f Image* *.zip

    if [ -f "$KIMG_DTB" ]; then
        cp "$KIMG_DTB" Image.gz-dtb
        IMG_USED="Image.gz-dtb"
    elif [ -f "$KIMG" ]; then
        cp "$KIMG" Image.gz
        IMG_USED="Image.gz"
    else
        echo "[!] Image.gz / Image.gz-dtb not found" | tee -a "$LOG"
        cd "$ROOTDIR"
        fail_variant
        return 1
    fi

    echo -e "$yellow[+] Zipping kernel...$white"
    zip -r9 "$ZIP_NAME" . -x ".git*" "README.md"

    mkdir -p "$ZIPS_DIR"
    mv "$ZIP_NAME" "$ZIPS_DIR/"
    cd "$ROOTDIR" || exit 1

    echo -e "$green[✓] Zip created: $ZIP_NAME ($IMG_USED)$white"
}

# ============= Upload To Pixeldrain & Safelinku =============
upload_variant() {
    ZIP_PATH="$ZIPS_DIR/$ZIP_NAME"
    [ ! -f "$ZIP_PATH" ] && return

    st_set "$VARIANT.status" uploading

    # ===== Upload to Pixeldrain =====
    echo -e "$yellow[+] Uploading to Pixeldrain...$white"
    PD_RESPONSE=$(curl -s -T "${ZIP_PATH}" -u :${PIXELDRAIN_API_KEY} "https://pixeldrain.com/api/file/${ZIP_NAME}")

    PD_ID=$(echo "$PD_RESPONSE" | jq -r '.id // empty')
    if [ -n "$PD_ID" ] && [ "$PD_ID" != "null" ]; then
        export PD_LINK="https://pixeldrain.com/u/${PD_ID}"
        echo -e "$green[✓] Pixeldrain Link: $PD_LINK$white"
    else
        echo -e "$red[✗] Upload Pixeldrain Gagal! Response: $PD_RESPONSE$white"
        export PD_LINK="Upload Failed"
    fi

    # ===== Generate Safelinku via Telegram Userbot =====
    echo -e "$yellow[+] Generating Safelinku via Telegram Userbot...$white"

    # Jalankan Python Telethon langsung di dalam Bash
    SL_LINK=$(python3 << 'EOF'
import asyncio, os, re, logging
from telethon import TelegramClient, events
from telethon.sessions import StringSession

# Sembunyikan warning telethon agar output bersih
logging.basicConfig(level=logging.ERROR)

api_id = os.environ.get("TELE_API_ID", "")
api_hash = os.environ.get("TELE_API_HASH", "")
session_string = os.environ.get("TELE_SESSION", "")
pd_link = os.environ.get("PD_LINK", "")
bot_username = "@safelinku_com_bot"

async def main():
    if not api_id or not api_hash or not session_string:
        print("Generation Failed (Missing Telegram Secrets)")
        return

    if pd_link == "Upload Failed":
        print("Generation Failed (Pixeldrain failed)")
        return

    client = TelegramClient(StringSession(session_string), int(api_id), api_hash)
    await client.start()
    
    loop = asyncio.get_event_loop()
    future = loop.create_future()
    
    @client.on(events.NewMessage(chats=bot_username))
    async def handler(event):
        text = event.message.message
        # Cek apakah bot membalas dengan link sfl.gl atau safelinku
        if "http" in text:
            urls = re.findall(r'(https?://[^\s]+)', text)
            if urls:
                future.set_result(urls[-1])
            else:
                future.set_result("Generation Failed (Bot replied without URL)")
    
    # Minta bot untuk membuat shortlink
    await client.send_message(bot_username, f"/shortlink {pd_link}")
    
    try:
        # Tunggu balasan dari bot maksimal 15 detik
        res = await asyncio.wait_for(future, timeout=15.0)
    except asyncio.TimeoutError:
        res = "Generation Failed (Bot Timeout)"
        
    print(res)
    await client.disconnect()

asyncio.run(main())
EOF
)

    # Validasi URL yang dikembalikan dari Python
    if [[ "$SL_LINK" == http* ]]; then
        echo -e "$green[✓] Safelinku Link: $SL_LINK$white"
    else
        echo -e "$red[✗] Safelinku Userbot Error: $SL_LINK$white"
        SL_LINK="Generation Failed"
    fi

    # ===== Simpan hasil ke state (tampil di pesan Telegram yang sama) =====
    st_set "$VARIANT.pd" "$PD_LINK"
    st_set "$VARIANT.sl" "$SL_LINK"

    # ===== Opsional: kirim zip sebagai pesan terpisah =====
    if [ "$SEND_FILES" = "1" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TG_CHAT_ID}" \
            -F document=@"${ZIP_PATH}" \
            -F caption="${KERNEL_NAME} ${VARIANT} ${DEVICE} ${KERNEL_VERSION}"
    fi
}

# ================= RUN =================
mkdir -p "$LOG_DIR" "$ZIPS_DIR" "$IMAGES_DIR"
trap 'touch "$STATE_DIR/stop"' EXIT

get_kernel_version
st_set total "$EST_OBJECTS"
for V in "${VARIANTS[@]}"; do
    st_set "$V.status" waiting
done

echo -e "$yellow[+] Sending telegram start...$white"
tg_start
tg_updater &
UPDATER_PID=$!

FAILED=0
for V in "${VARIANTS[@]}"; do
    VARIANT="$V"
    LOG="$LOG_DIR/build-${VARIANT}.txt"
    : > "$LOG"

    echo -e "$yellow========== Variant: ${VARIANT} ==========$white"

    if build_kernel && pack_kernel && upload_variant; then
        st_set "$VARIANT.end" "$(date +%s)"
        st_set "$VARIANT.status" "done"
    else
        FAILED=$((FAILED + 1))
    fi
done

# ===== Final: hentikan updater, lalu edit pesan terakhir =====
END=$(TZ=Asia/Jakarta date +%s)
st_set end_all "$END"
if [ "$FAILED" -eq 0 ]; then
    st_set final success
elif [ "$FAILED" -lt "${#VARIANTS[@]}" ]; then
    st_set final partial
else
    st_set final failed
fi

touch "$STATE_DIR/stop"
wait "$UPDATER_PID" 2>/dev/null
tg_edit "$(render_msg "$END")"

echo -e "$green[✓] Done in $((END - START)) seconds$white"
[ "$FAILED" -eq 0 ] || exit 1
