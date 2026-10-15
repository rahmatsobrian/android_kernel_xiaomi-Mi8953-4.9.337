#!/bin/bash

# ================= COLOR =================
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
white='\033[0m'

# ================= PATH =================
DEFCONFIG="msm8953-perf_defconfig"
FRAGMENT="mi8953.config"
ROOTDIR=$(pwd)
KSU_DIR="KernelSU"

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

# ================= IPC / STATUS DIRECTORY =================
STATUS_DIR="/tmp/yoru_build_status"
rm -rf "$STATUS_DIR"
mkdir -p "$STATUS_DIR"
mkdir -p "$ROOTDIR/logs"

MSG_ID=""
KERNEL_VERSION="unknown"
KSU_VERSION="unknown"

# Initial State
echo "pending" > "$STATUS_DIR/state_KSU"
echo "pending" > "$STATUS_DIR/state_NonKSU"

# ================= FUNCTION =================
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

get_ksu_version() {
    if [ -f "$KSU_DIR/kernel/Makefile" ]; then
        KSU_VERSION=$(grep -E 'KSU_VERSION=' "$KSU_DIR/kernel/Makefile" | awk -F'KSU_VERSION=' '{print $2}')
        KSU_VERSION=$(echo "$KSU_VERSION" | tr -d ' ' | tr -d '\n')
        if [ -z "$KSU_VERSION" ]; then
             KSU_VERSION="Unknown"
        else
             KSU_VERSION="v${KSU_VERSION}"
        fi
    else
        KSU_VERSION="Unknown"
    fi
}

send_telegram_start() {
    RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode=Markdown \
        -d disable_web_page_preview=true \
        -d text="🚀 *Kernel CI Build Started (Parallel)*

📱 *Device* : ${DEVICE}
📦 *Kernel Name* : ${KERNEL_NAME}
🍃 *Kernel Version* : ${KERNEL_VERSION}
🦸 *KSU Version* : ${KSU_VERSION}

⚙️ *KSU Variant* : ⏳ Starting...
⚙️ *NonKSU Variant* : ⏳ Starting...")

    MSG_ID=$(echo "$RESPONSE" | jq -r '.result.message_id // empty')
}

update_status() {
    local text="$1"
    [ -z "$MSG_ID" ] && return
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText" \
        -d chat_id="${TG_CHAT_ID}" \
        -d message_id="${MSG_ID}" \
        -d parse_mode=Markdown \
        -d disable_web_page_preview=true \
        -d text="$text" > /dev/null
}

send_telegram_log() {
    local variant="$1"
    local LOG_FILE="$ROOTDIR/logs/build-${variant}.txt"
    [ ! -f "$LOG_FILE" ] && return
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"${LOG_FILE}" \
        -F caption="📄 Build Log (${variant})" > /dev/null
}

# ================= PARALLEL BUILD WORKER =================
build_single_variant() {
    local VARIANT="$1"
    local OUTDIR_VAR="$ROOTDIR/out_${VARIANT}"
    local ANYKERNEL_VAR="$ROOTDIR/AnyKernel_${VARIANT}"
    local TEMP_DEFCONFIG_VAR="msm8953_${VARIANT}_defconfig"
    local LOG_FILE="$ROOTDIR/logs/build-${VARIANT}.txt"

    echo "compiling" > "$STATUS_DIR/state_${VARIANT}"

    rm -rf "$OUTDIR_VAR"
    mkdir -p "$OUTDIR_VAR"

    cp arch/arm64/configs/${DEFCONFIG} arch/arm64/configs/${TEMP_DEFCONFIG_VAR}

    if [ "$VARIANT" == "NonKSU" ]; then
        sed -i 's/CONFIG_KSU=y/# CONFIG_KSU is not set/g' arch/arm64/configs/${TEMP_DEFCONFIG_VAR}
    fi

    # Config
    make O="out_${VARIANT}" ARCH=arm64 "${TEMP_DEFCONFIG_VAR}" ${FRAGMENT} > "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        echo "failed" > "$STATUS_DIR/state_${VARIANT}"
        return 1
    fi

    # Build Kernel
    make -j$(nproc --all) \
      ARCH=arm64 \
      O="out_${VARIANT}" \
      CC=clang \
      CROSS_COMPILE=aarch64-linux-gnu- \
      CROSS_COMPILE_ARM32=arm-linux-gnueabi- >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        echo "failed" > "$STATUS_DIR/state_${VARIANT}"
        return 1
    fi

    local BUILD_END=$(TZ=Asia/Jakarta date +%s)
    local START_VAR=$(cat "$STATUS_DIR/start_${VARIANT}")
    local DIFF=$((BUILD_END - START_VAR))
    local B_TIME="$((DIFF / 60)) min $((DIFF % 60)) sec"
    echo "$B_TIME" > "$STATUS_DIR/time_${VARIANT}"

    # Packing AnyKernel3
    echo "packing" > "$STATUS_DIR/state_${VARIANT}"
    rm -rf "$ANYKERNEL_VAR"
    git clone -q -b ${DEVICE} https://github.com/rahmatsobrian/AnyKernel3.git "$ANYKERNEL_VAR" >> "$LOG_FILE" 2>&1

    cd "$ANYKERNEL_VAR" || { echo "failed" > "$STATUS_DIR/state_${VARIANT}"; return 1; }
    rm -f Image* *.zip

    local KIMG_DTB="$OUTDIR_VAR/arch/arm64/boot/Image.gz-dtb"
    local KIMG="$OUTDIR_VAR/arch/arm64/boot/Image.gz"
    local ZIP_NAME="${KERNEL_NAME}-${VARIANT}-${DEVICE}-${KERNEL_VERSION}-${DATE_TITLE}-${TIME_TITLE}.zip"

    if [ -f "$KIMG_DTB" ]; then
        cp "$KIMG_DTB" Image.gz-dtb
    elif [ -f "$KIMG" ]; then
        cp "$KIMG" Image.gz
    else
        cd "$ROOTDIR"
        echo "failed" > "$STATUS_DIR/state_${VARIANT}"
        return 1
    fi

    zip -r9 "$ZIP_NAME" . -x ".git*" "README.md" >> "$LOG_FILE" 2>&1
    local ZIP_PATH="$ANYKERNEL_VAR/$ZIP_NAME"
    cd "$ROOTDIR"

    # Upload Pixeldrain
    echo "uploading" > "$STATUS_DIR/state_${VARIANT}"
    local PD_RESPONSE=$(curl -s -T "${ZIP_PATH}" -u :${PIXELDRAIN_API_KEY} "https://pixeldrain.com/api/file/${ZIP_NAME}")
    local PD_ID=$(echo "$PD_RESPONSE" | jq -r '.id // empty')
    local PD_LINK="Upload Failed"
    if [ -n "$PD_ID" ] && [ "$PD_ID" != "null" ]; then
        PD_LINK="https://pixeldrain.com/u/${PD_ID}"
    fi

    # Safelinku via Telethon (dikunci dengan flock agar tidak bentrok)
    local SL_LINK="Generation Failed"
    (
        flock -x 200
        SL_LINK=$(python3 << EOF
import asyncio, os, re, logging
from telethon import TelegramClient, events
from telethon.sessions import StringSession

logging.basicConfig(level=logging.ERROR)

api_id = os.environ.get("TELE_API_ID", "")
api_hash = os.environ.get("TELE_API_HASH", "")
session_string = os.environ.get("TELE_SESSION", "")
pd_link = "${PD_LINK}"
bot_username = "@safelinku_com_bot"

async def main():
    if not api_id or not api_hash or not session_string or pd_link == "Upload Failed":
        print("Generation Failed")
        return

    client = TelegramClient(StringSession(session_string), int(api_id), api_hash)
    await client.start()
    
    loop = asyncio.get_event_loop()
    future = loop.create_future()
    
    @client.on(events.NewMessage(chats=bot_username))
    async def handler(event):
        text = event.message.message
        if "http" in text:
            urls = re.findall(r'(https?://[^\s]+)', text)
            if urls:
                future.set_result(urls[-1])
            else:
                future.set_result("Generation Failed")
    
    await client.send_message(bot_username, f"/shortlink {pd_link}")
    
    try:
        res = await asyncio.wait_for(future, timeout=15.0)
    except asyncio.TimeoutError:
        res = "Generation Failed"
        
    print(res)
    await client.disconnect()

asyncio.run(main())
EOF
)
    ) 200>/tmp/telethon.lock

    if [ "$SL_LINK" != "Generation Failed" ] && [[ "$SL_LINK" == http* ]]; then
        echo "🔗 [Direct](${PD_LINK}) | 💰 [Safelinku](${SL_LINK})" > "$STATUS_DIR/link_${VARIANT}"
    else
        echo "🔗 [Direct](${PD_LINK}) | ⚠️ Safelinku Failed" > "$STATUS_DIR/link_${VARIANT}"
    fi

    # Kirim dokumen zip ke Telegram
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"${ZIP_PATH}" \
        -F caption="📦 ${ZIP_NAME}" > /dev/null

    echo "finished" > "$STATUS_DIR/state_${VARIANT}"
}

# ================= EXECUTION =================
get_kernel_version
get_ksu_version
send_telegram_start

START_TIME=$(TZ=Asia/Jakarta date +%s)
echo "$START_TIME" > "$STATUS_DIR/start_KSU"
echo "$START_TIME" > "$STATUS_DIR/start_NonKSU"

# Jalankan 2 build secara PARALEL (di background)
build_single_variant "KSU" &
PID_KSU=$!

build_single_variant "NonKSU" &
PID_NONKSU=$!

# Monitor & Update 1 Pesan Telegram secara Real-time
while kill -0 $PID_KSU 2>/dev/null || kill -0 $PID_NONKSU 2>/dev/null; do
    sleep 10
    NOW=$(TZ=Asia/Jakarta date +%s)

    # Status KSU
    ST_KSU=$(cat "$STATUS_DIR/state_KSU" 2>/dev/null)
    if [ "$ST_KSU" == "compiling" ]; then
        DIFF_KSU=$((NOW - START_TIME))
        TXT_KSU="🛠️ Compiling... (⏱️ $((DIFF_KSU / 60))m $((DIFF_KSU % 60))s)"
    elif [ "$ST_KSU" == "packing" ]; then
        TXT_KSU="📦 Packing AnyKernel3..."
    elif [ "$ST_KSU" == "uploading" ]; then
        TXT_KSU="☁️ Uploading..."
    elif [ "$ST_KSU" == "finished" ]; then
        TXT_KSU="✅ Finished ($(cat "$STATUS_DIR/time_KSU" 2>/dev/null))"
    elif [ "$ST_KSU" == "failed" ]; then
        TXT_KSU="❌ Failed"
    else
        TXT_KSU="⏳ Pending..."
    fi

    # Status NonKSU
    ST_NONKSU=$(cat "$STATUS_DIR/state_NonKSU" 2>/dev/null)
    if [ "$ST_NONKSU" == "compiling" ]; then
        DIFF_NONKSU=$((NOW - START_TIME))
        TXT_NONKSU="🛠️ Compiling... (⏱️ $((DIFF_NONKSU / 60))m $((DIFF_NONKSU % 60))s)"
    elif [ "$ST_NONKSU" == "packing" ]; then
        TXT_NONKSU="📦 Packing AnyKernel3..."
    elif [ "$ST_NONKSU" == "uploading" ]; then
        TXT_NONKSU="☁️ Uploading..."
    elif [ "$ST_NONKSU" == "finished" ]; then
        TXT_NONKSU="✅ Finished ($(cat "$STATUS_DIR/time_NonKSU" 2>/dev/null))"
    elif [ "$ST_NONKSU" == "failed" ]; then
        TXT_NONKSU="❌ Failed"
    else
        TXT_NONKSU="⏳ Pending..."
    fi

    update_status "🛠️ *Building Yoru Kernel (Parallel)*

📱 *Device* : ${DEVICE}
⚙️ *Compiler* : ZyC Clang

🦸 *KSU Variant* (${KSU_VERSION})
Status : ${TXT_KSU}

🍃 *NonKSU Variant*
Status : ${TXT_NONKSU}"
done

wait $PID_KSU
wait $PID_NONKSU

# Hasil Akhir
ST_KSU=$(cat "$STATUS_DIR/state_KSU" 2>/dev/null)
ST_NONKSU=$(cat "$STATUS_DIR/state_NonKSU" 2>/dev/null)

if [ "$ST_KSU" == "finished" ] && [ "$ST_NONKSU" == "finished" ]; then
    update_status "🔥 *Kernel CI Build Success*

📱 *Device* : ${DEVICE}
📦 *Kernel Name* : ${KERNEL_NAME}
🍃 *Kernel Version* : ${KERNEL_VERSION}
🕒 *Build Date* : ${BUILD_DATETIME}

🦸 *KSU Variant* (${KSU_VERSION})
⌛ Build Time : $(cat "$STATUS_DIR/time_KSU")
📥 Links : $(cat "$STATUS_DIR/link_KSU")

🍃 *NonKSU Variant*
⌛ Build Time : $(cat "$STATUS_DIR/time_NonKSU")
📥 Links : $(cat "$STATUS_DIR/link_NonKSU")"

    send_telegram_log "KSU"
    send_telegram_log "NonKSU"
    echo -e "$green[✓] Parallel builds completed successfully!$white"
else
    update_status "❌ *Kernel CI Build Failed*

📱 *Device* : ${DEVICE}
📦 *Kernel Name* : ${KERNEL_NAME}
🦸 *KSU Status* : ${ST_KSU}
🍃 *NonKSU Status* : ${ST_NONKSU}

📄 *Log files attached below*"

    [ "$ST_KSU" == "failed" ] && send_telegram_log "KSU"
    [ "$ST_NONKSU" == "failed" ] && send_telegram_log "NonKSU"
    exit 1
fi
