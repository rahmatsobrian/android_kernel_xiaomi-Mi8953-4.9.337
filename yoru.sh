#!/bin/bash

# ================= COLOR =================
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
white='\033[0m'

# ================= PATH =================
DEFCONFIG="msm8953-perf_defconfig"
FRAGMENT="mi8953.config"
TEMP_DEFCONFIG="msm8953-perf_temp_defconfig"
ROOTDIR=$(pwd)
OUTDIR="$ROOTDIR/out/arch/arm64/boot"
ANYKERNEL_DIR="$ROOTDIR/AnyKernel"
KIMG_DTB="$OUTDIR/Image.gz-dtb"
KIMG="$OUTDIR/Image.gz"
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

# ================= GLOBAL STATE =================
MSG_ID=""
KSU_VERSION="unknown"

STATUS_KSU="⏳ Pending"
STATUS_NONKSU="⏳ Pending"

TIME_KSU="-"
TIME_NONKSU="-"

DL_TEXT_KSU="Pending"
DL_TEXT_NONKSU="Pending"

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
        -d text="🚀 *Kernel CI Build Started*

📱 *Device* : ${DEVICE}
📦 *Kernel Name* : ${KERNEL_NAME}
🍃 *Kernel Version* : ${KERNEL_VERSION}
🦸 *KSU Version* : ${KSU_VERSION}

⚙️ *KSU Variant* : ⏳ Pending
⚙️ *NonKSU Variant* : ⏳ Pending")

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

render_progress_message() {
    echo "🛠️ *Building Yoru Kernel*

📱 *Device* : ${DEVICE}
⚙️ *Compiler* : ZyC Clang

🦸 *KSU Variant* (${KSU_VERSION})
Status : ${STATUS_KSU}

🍃 *NonKSU Variant*
Status : ${STATUS_NONKSU}"
}

send_telegram_error() {
    local failed_variant="$1"
    update_status "❌ *Kernel CI Build Failed*

📱 *Device* : ${DEVICE}
⚠️ *Failed Variant* : ${failed_variant}

📄 *Log file attached below*"

    LOG_FILE="$ROOTDIR/logs/build-${failed_variant}.txt"
    if [ -f "$LOG_FILE" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TG_CHAT_ID}" \
            -F document=@"${LOG_FILE}" > /dev/null
    fi
}

# ================= BUILD PROCESS FOR A VARIANT =================
build_single_variant() {
    VARIANT="$1"
    echo -e "$yellow[+] Starting Build for ${VARIANT}...$white"

    rm -rf out
    mkdir -p out

    cp arch/arm64/configs/${DEFCONFIG} arch/arm64/configs/${TEMP_DEFCONFIG}

    if [ "$VARIANT" == "NonKSU" ]; then
        sed -i 's/CONFIG_KSU=y/# CONFIG_KSU is not set/g' arch/arm64/configs/${TEMP_DEFCONFIG}
    fi

    make O=out ARCH=arm64 ${TEMP_DEFCONFIG} ${FRAGMENT} > /dev/null 2>&1 || {
        send_telegram_error "$VARIANT"
        exit 1
    }

    BUILD_START=$(TZ=Asia/Jakarta date +%s)

    # Loop update status real-time per 10 detik
    (
        while true; do
            sleep 10
            NOW=$(TZ=Asia/Jakarta date +%s)
            DIFF=$((NOW - BUILD_START))
            MIN=$((DIFF / 60))
            SEC=$((DIFF % 60))
            
            if [ "$VARIANT" == "KSU" ]; then
                STATUS_KSU="🛠️ Compiling... (⏱️ ${MIN}m ${SEC}s)"
            else
                STATUS_NONKSU="🛠️ Compiling... (⏱️ ${MIN}m ${SEC}s)"
            fi
            
            update_status "$(render_progress_message)"
        done
    ) &
    UPDATER_PID=$!

    make -j$(nproc --all) \
      ARCH=arm64 \
      O=out \
      CC=clang \
      CROSS_COMPILE=aarch64-linux-gnu- \
      CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    MAKE_EXIT_CODE=$?

    kill $UPDATER_PID 2>/dev/null
    wait $UPDATER_PID 2>/dev/null

    if [ $MAKE_EXIT_CODE -ne 0 ]; then
        if [ "$VARIANT" == "KSU" ]; then STATUS_KSU="❌ Build Failed"; else STATUS_NONKSU="❌ Build Failed"; fi
        send_telegram_error "$VARIANT"
        exit 1
    fi

    BUILD_END=$(TZ=Asia/Jakarta date +%s)
    DIFF=$((BUILD_END - BUILD_START))
    BUILD_TIME="$((DIFF / 60)) min $((DIFF % 60)) sec"

    if [ "$VARIANT" == "KSU" ]; then
        TIME_KSU="$BUILD_TIME"
        STATUS_KSU="✅ Finished (${BUILD_TIME})"
    else
        TIME_NONKSU="$BUILD_TIME"
        STATUS_NONKSU="✅ Finished (${BUILD_TIME})"
    fi

    update_status "$(render_progress_message)"

    # --- PACKING ---
    ZIP_NAME="${KERNEL_NAME}-${VARIANT}-${DEVICE}-${KERNEL_VERSION}-${DATE_TITLE}-${TIME_TITLE}.zip"
    clone_anykernel
    cd "$ANYKERNEL_DIR" || exit 1
    rm -f Image* *.zip

    if [ -f "$KIMG_DTB" ]; then
        cp "$KIMG_DTB" Image.gz-dtb
    elif [ -f "$KIMG" ]; then
        cp "$KIMG" Image.gz
    else
        send_telegram_error "$VARIANT"
        exit 1
    fi

    zip -r9 "$ZIP_NAME" . -x ".git*" "README.md"
    ZIP_PATH="$ANYKERNEL_DIR/$ZIP_NAME"
    cd "$ROOTDIR" || exit 1

    # --- UPLOADING ---
    echo -e "$yellow[+] Uploading ${VARIANT} to Pixeldrain...$white"
    PD_RESPONSE=$(curl -s -T "${ZIP_PATH}" -u :${PIXELDRAIN_API_KEY} "https://pixeldrain.com/api/file/${ZIP_NAME}")
    PD_ID=$(echo "$PD_RESPONSE" | jq -r '.id // empty')
    
    if [ -n "$PD_ID" ] && [ "$PD_ID" != "null" ]; then
        PD_LINK="https://pixeldrain.com/u/${PD_ID}"
    else
        PD_LINK="Upload Failed"
    fi

    # Generate Safelinku
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

    if [ "$VARIANT" == "KSU" ]; then
        DL_TEXT_KSU="🔗 [Direct](${PD_LINK}) | 💰 [Safelinku](${SL_LINK})"
    else
        DL_TEXT_NONKSU="🔗 [Direct](${PD_LINK}) | 💰 [Safelinku](${SL_LINK})"
    fi

    # Kirim file zip lampiran
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"${ZIP_PATH}" \
        -F caption="📦 ${ZIP_NAME}" > /dev/null
}

# ================= MAIN EXECUTION =================
get_kernel_version
get_ksu_version
send_telegram_start

# 1. Build KSU
build_single_variant "KSU"

# 2. Build NonKSU
build_single_variant "NonKSU"

# 3. Final Summary Update (Ke 1 pesan yang sama)
update_status "🔥 *Kernel CI Build Success*

📱 *Device* : ${DEVICE}
📦 *Kernel Name* : ${KERNEL_NAME}
🍃 *Kernel Version* : ${KERNEL_VERSION}
🕒 *Build Date* : ${BUILD_DATETIME}

🦸 *KSU Variant* (${KSU_VERSION})
⌛ Build Time : ${TIME_KSU}
📥 Links : ${DL_TEXT_KSU}

🍃 *NonKSU Variant*
⌛ Build Time : ${TIME_NONKSU}
📥 Links : ${DL_TEXT_NONKSU}"

echo -e "$green[✓] All builds completed successfully!$white"
