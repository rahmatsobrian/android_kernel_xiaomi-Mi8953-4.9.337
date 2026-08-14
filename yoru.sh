#!/bin/bash

# ================= COLOR =================
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
white='\033[0m'

# ================= VARIANT =================
VARIANT=$1
if [ -z "$VARIANT" ]; then
    VARIANT="KSU"
fi

# ================= PATH =================
DEFCONFIG="msm8953-perf_defconfig"
FRAGMENT="mi8953.config"
TEMP_DEFCONFIG="msm8953-perf_temp_defconfig"
ROOTDIR=$(pwd)
OUTDIR="$ROOTDIR/out/arch/arm64/boot"
ANYKERNEL_DIR="$ROOTDIR/AnyKernel"
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

# ================= GLOBAL =================
BUILD_TIME="unknown"
KERNEL_VERSION="unknown"
IMG_USED="unknown"
ZIP_NAME=""

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

send_telegram_error() {
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode=Markdown \
        -d text="❌ *Kernel CI Build Test Failed [${VARIANT}]*

📄 *Log attached below*"

    send_telegram_log
}

send_telegram_start() {
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode=Markdown \
        -d text="🚀 *Kernel CI Build Test Started [${VARIANT}]*"
}

send_telegram_log() {
    LOG_FILE="$ROOTDIR/logs/build-${VARIANT}.txt"
    [ ! -f "$LOG_FILE" ] && return
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"${LOG_FILE}"
}

# ================= Build Kernel =================
build_kernel() {
    echo -e "$yellow[+] Sending telegram start...$white"
    send_telegram_start

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
make O=out ARCH=arm64 ${TEMP_DEFCONFIG} ${FRAGMENT} || {
    send_telegram_error
    exit 1
}

    BUILD_START=$(TZ=Asia/Jakarta date +%s)

    echo -e "$yellow[+] Building Kernel [${VARIANT}]...$white"
    make -j$(nproc --all) \
  ARCH=arm64 \
  O=out \
  CC=clang \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- || {
            send_telegram_error
            exit 1
        }

    BUILD_END=$(TZ=Asia/Jakarta date +%s)
    DIFF=$((BUILD_END - BUILD_START))
    BUILD_TIME="$((DIFF / 60)) min $((DIFF % 60)) sec"

    echo -e "$yellow[+] Getting kernel version...$white"
    get_kernel_version

    ZIP_NAME="${KERNEL_NAME}-${VARIANT}-${DEVICE}-${KERNEL_VERSION}-${DATE_TITLE}-${TIME_TITLE}.zip"
}

# =============== Zipping Kernel ===============
pack_kernel() {
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
        send_telegram_error
        exit 1
    fi

    echo -e "$yellow[+] Zipping kernel...$white"
    zip -r9 "$ZIP_NAME" . -x ".git*" "README.md"

    echo -e "$green[✓] Zip created: $ZIP_NAME ($IMG_USED)$white"
}

# ============= Upload To Pixeldrain & Telegram =============
upload_telegram() {
    ZIP_PATH="$ANYKERNEL_DIR/$ZIP_NAME"
    [ ! -f "$ZIP_PATH" ] && return

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

    # ===== Send to Telegram =====
    echo -e "$yellow[+] Sending message to Telegram...$white"

    if [ "$SL_LINK" != "Generation Failed" ]; then
        DOWNLOAD_TEXT="📥 *Download Links*:
🔗 [Direct Download (Pixeldrain)](${PD_LINK})
💰 [Support via Safelinku](${SL_LINK})"
    else
        DOWNLOAD_TEXT="📥 *Download Links*:
🔗 [Direct Download (Pixeldrain)](${PD_LINK})
⚠️ Safelinku: Generation Failed"
    fi

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"${ZIP_PATH}" \
        -F parse_mode="Markdown" \
        -F caption="🔥 *Kernel CI Build Test Success*

📱 *Device* : ${DEVICE}
📦 *Kernel Name* : ${KERNEL_NAME}
🏷️ *Variant* : ${VARIANT}
🍃 *Kernel Version* : ${KERNEL_VERSION}

⌛ *Build Time* : ${BUILD_TIME}
🕒 *Build Date* : ${BUILD_DATETIME}

${DOWNLOAD_TEXT}"

    send_telegram_log
}

# ================= RUN =================
START=$(TZ=Asia/Jakarta date +%s)

build_kernel
pack_kernel
upload_telegram

END=$(TZ=Asia/Jakarta date +%s)
echo -e "$green[✓] Done in $((END - START)) seconds$white"
