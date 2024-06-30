#!/system/bin/sh

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
   echo "This script must be run as root" 
   exit 1
fi

# Define the path to the build.prop file and output directory
device_codename=$(getprop "ro.product.device" || echo "")
BUILD_PROP_PATH="/storage/emulated/0/Documents/${device_codename}/build.prop"
LOG_FILE="/storage/emulated/0/Documents/${device_codename}/build_log.txt"
VAR_FILE_PATH="/storage/emulated/0/Documents/${device_codename}/getvar.txt"
OUTPUT_FSTAB="/storage/emulated/0/Documents/${device_codename)/rootdir/etc/fstab.${device_codename}"

# Define output directory
device_codename=$(getprop "ro.product.device" || echo "")
output_dir="/storage/emulated/0/Documents/${device_codename}"
mkdir -p "$output_dir/rootdir/etc"

# Initialize log file
echo "Device tree generation started" > "$LOG_FILE"

# Function to extract variables from getvar.txt
extract_variable() {
    local variable=$1
    grep "$variable" "VAR_FILE_PATH" | cut -d'=' -f2
}

# Function to check and install necessary tools
check_install_tools() {
    # Check for necessary tools
    if ! command -v cp >/dev/null 2>&1; then
        echo "'cp' command not found. Please ensure it's available."
        exit 1
    fi

    if ! command -v dd >/dev/null 2>&1; then
        echo "'dd' command not found. Please ensure it's available."
        exit 1
    fi
}

# Function to find device directory
find_device_directory() {
    local device_dir=$(find / -type d -name "system" -exec dirname {} \; 2>/dev/null)
    if [ -z "$device_dir" ]; then
        echo "Device directory not found. Exiting."
        exit 1
    fi
    echo "$device_dir"
}

# Function to find and process all .prop files
process_prop_files() {
    local device_dir="$1"

    # Find all .prop files in device directory and subdirectories
    local prop_files=$(find "$device_dir" -type f -name "*.prop" 2>/dev/null)

    if [ -z "$prop_files" ]; then
        echo "No .prop files found in $device_dir or its subdirectories."
    else
        echo "Processing .prop files:"
        for file in $prop_files; do
            echo "File: $file"
            # Example action: Print content of the .prop file
            cat "$file"
            echo "---"
        done
    fi
}

# Function to find build.prop file or create it using getprop
find_or_generate_build_prop() {
    local device_codename=$(getprop "ro.product.device" || echo "")
    local output_dir="/storage/emulated/0/Documents/${device_codename}"
    local build_prop="$output_dir/build.prop"

    if [ ! -f "$build_prop" ]; then
        echo "Build.prop file not found. Generating from getprop..."
        getprop > "$build_prop"
        if [ $? -ne 0 ]; then
            echo "Failed to generate build.prop. Exiting."
            exit 1
        fi
    fi

    echo "Build.prop found or generated: $build_prop"
}

# Function to extract ramdisk from boot image
extract_ramdisk() {
    local boot_img="/dev/block/sdd22"  # Adjust this path according to your environment
    if [ ! -e "$boot_img" ]; then
        echo "Boot image not found at $boot_img. Exiting."
        exit 1
    fi

    local ramdisk_output="$output_dir/kernel/ramdisk.img"
    mkdir -p "$(dirname "$ramdisk_output")"

    # Actual extraction command using dd to copy raw data
    dd if="$boot_img" of="$ramdisk_output" bs=1 skip=32768 count=131072
    if [ $? -ne 0 ]; then
        echo "Failed to extract ramdisk from boot image. Exiting."
        exit 1
    fi

    echo "Ramdisk extracted to: $ramdisk_output"
}

device_codename=$(getprop "ro.product.device" || echo "")
PARTITION_OUTPUT_FILE="/storage/emulated/0/Documents/${device_codename}/partition_sizes.txt"
mkdir -p $(dirname "$PARTITION_OUTPUT_FILE")

# Clear the output file if it already exists
> "$PARTITION_OUTPUT_FILE"

# Function to convert blocks to bytes using awk for large numbers
blocks_to_bytes() {
    echo "$1" | awk '{print $1 * 512}'
}

# Function to get the file system type from /proc/mounts
get_filesystem_type() {
    DEVICE=$1
    # Search for the device in /proc/mounts and get the filesystem type
    FILE_SYSTEM_TYPE=$(grep " $DEVICE " /proc/mounts | awk '{print $3}' | head -n 1)
    if [ -z "$FILE_SYSTEM_TYPE" ]; then
        FILE_SYSTEM_TYPE=$(grep " $(basename "$DEVICE") " /proc/mounts | awk '{print $3}' | head -n 1)
    fi
    echo "$FILE_SYSTEM_TYPE"
}

# Function to process block devices
process_block_device() {
    BLOCK_DEVICE=$1
    LINKED_NAME=$2
    DEVICE_NAME=$(basename "$(readlink -f "$BLOCK_DEVICE")")
    REAL_PATH=$(realpath "$BLOCK_DEVICE")
    
    # Get file system type
    FILE_SYSTEM_TYPE=$(get_filesystem_type "$REAL_PATH")

    # Get the size in blocks and convert to bytes
    SIZE_BLOCKS=$(cat /sys/class/block/${DEVICE_NAME}/size 2>/dev/null)
    if [ -z "$SIZE_BLOCKS" ] || [ "$SIZE_BLOCKS" -lt 0 ]; then
        return
    fi
    TRUE_BYTE_SIZE=$(blocks_to_bytes "$SIZE_BLOCKS")

    echo "Linked Name: $LINKED_NAME" >> "$PARTITION_OUTPUT_FILE"
    echo "Name: $DEVICE_NAME" >> "$PARTITION_OUTPUT_FILE"
    echo "Real Path: $REAL_PATH" >> "$PARTITION_OUTPUT_FILE"
    echo "File System Type: $FILE_SYSTEM_TYPE" >> "$PARTITION_OUTPUT_FILE"
    echo "$LINKED_NAME: $TRUE_BYTE_SIZE" >> "$PARTITION_OUTPUT_FILE"
    echo "" >> "$PARTITION_OUTPUT_FILE"
}

# Function to traverse directories and process block devices
traverse_and_process() {
    for ENTRY in "$1"/*; do
        if [ -d "$ENTRY" ]; then
            case $(basename "$ENTRY") in
                bootdevice|mapper|platform|vold|by-name)
                    continue
                    ;;
                *)
                    traverse_and_process "$ENTRY"
                    ;;
            esac
        elif [ -b "$ENTRY" ]; then
            process_block_device "$ENTRY" "$(basename "$ENTRY")"
        fi
    done
}

# Function to process linked names in specific directories
process_linked_names() {
    LINK_DIR=$1
    for LINK in "$LINK_DIR"/*; do
        if [ -h "$LINK" ]; then
            REAL_DEVICE=$(realpath "$LINK")
            process_block_device "$REAL_DEVICE" "$(basename "$LINK")"
        fi
    done
}

# Process linked names in /dev/block/bootdevice/by-name and /dev/block/mapper
process_linked_names "/dev/block/bootdevice/by-name"
process_linked_names "/dev/block/mapper"

# Traverse other block devices
traverse_and_process "/dev/block"

echo "Partition information written to $PARTITION_OUTPUT_FILE"

# Create the directory if it does not exist
DIRECTORY="/storage/emulated/0/Documents/${device_codename}"
if [ ! -d "$DIRECTORY" ]; then
    mkdir -p "$DIRECTORY"
fi

# Write properties to files
write_properties() {
    local properties=$1
    local filename=$2
    echo "$properties" > "$OUTPUT_DIR/$filename"
    echo "Generated $filename" >> "$LOG_FILE"
}

# Create BoardConfig.mk
create_BoardConfig_mk() {
    local device_codename=$(getprop "ro.product.device" || echo "")
    local manufacturer=$(getprop "ro.product.manufacturer" || echo "")
    local arch=$(getprop "ro.product.cpu.abi" || echo "")
    local screen_density=$(getprop "ro.sf.lcd_density" || echo "")

    local properties="
# A/B
AB_OTA_UPDATER := $(getprop "ro.build.ab_update" || echo "")
AB_OTA_PARTITIONS +=
# Architecture
TARGET_ARCH := $(getprop "ro.bionic.arch" || echo "")
TARGET_ARCH_VARIANT := $(getprop "ro.system.product.cpu.abi" || echo "")
TARGET_CPU_ABI := $(getprop "ro.system.product.cpu.abilist64" | cut -d',' -f1 || echo "")
TARGET_CPU_ABI2 := $(getprop "ro.system.product.cpu.abilist64" | cut -d',' -f2 || echo "")
TARGET_CPU_VARIANT := $(getprop "ro.bionic.cpu_variant" || echo "")
TARGET_CPU_VARIANT_RUNTIME := ${arch}

TARGET_2ND_ARCH := $(getprop "ro.bionic.2nd_arch" || echo "")
TARGET_2ND_ARCH_VARIANT := $(getprop "ro.system.product.cpu.abilist32" | cut -d',' -f1 || echo "")
TARGET_2ND_CPU_ABI := $(getprop "ro.system.product.cpu.abilist32" | cut -d',' -f1 || echo "")
TARGET_2ND_CPU_ABI2 := $(getprop "ro.system.product.cpu.abilist32" | cut -d',' -f2 || echo "")
TARGET_2ND_CPU_VARIANT := $(getprop "ro.bionic.2nd_cpu_variant" || echo "")
TARGET_2ND_CPU_VARIANT_RUNTIME := ${arch}

TARGET_USES_64_BIT_BINDER := true

OVERRIDE_TARGET_FLATTEN_APEX := true

# Bootloader
TARGET_BOOTLOADER_BOARD_NAME := ${device_codename}
TARGET_NO_BOOTLOADER := true

# Display
TARGET_SCREEN_DENSITY := ${screen_density}
TARGET_USES_VULKAN := $(getprop "ro.hwui.use_vulkan" || echo "")

# Kernel
BOARD_KERNEL_BASE := 0x80000000
BOARD_KERNEL_CMDLINE := console=ttyHSL0,115200,n8 androidboot.hardware=qcom user_debug=31 msm_rtb.filter=0x37 ehci-hcd.park=3
BOARD_KERNEL_PAGESIZE := 4096
BOARD_KERNEL_IMAGE_NAME := Image
BOARD_KERNEL_SEPARATED_DT := true
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_KERNEL_SEPARATED_DTBO := true
TARGET_KERNEL_CONFIG := ${device_codename}_defconfig
TARGET_KERNEL_SOURCE := kernel/$(echo "${manufacturer}" | tr '[:lower:]' '[:upper:]')/${device_codename}

TARGET_FORCE_PREBUILT_KERNEL := true
ifeq (\$(TARGET_FORCE_PREBUILT_KERNEL),true)
TARGET_PREBUILT_KERNEL := \$(DEVICE_PATH)/prebuilts/kernel
TARGET_PREBUILT_DT := \$(DEVICE_PATH)/prebuilts/dt.img
BOARD_MKBOOTIMG_ARGS += --dt \$(TARGET_PREBUILT_DT)
BOARD_KERNEL_SEPARATED_DT := 
TARGET_PREBUILT_DTB := \$(DEVICE_PATH)/prebuilts/dtb.img
BOARD_MKBOOTIMG_ARGS += --dtb \$(TARGET_PREBUILT_DTB)
BOARD_INCLUDE_DTB_IN_BOOTIMG := 
BOARD_PREBUILT_DTBOIMAGE := \$(DEVICE_PATH)/prebuilts/dtbo.img
BOARD_KERNEL_SEPARATED_DTBO := 
endif

# Partitions
BOARD_BUILD_SYSTEM_ROOT_IMAGE := true
BOARD_FLASH_BLOCK_SIZE := 262144 # (BOARD_KERNEL_PAGESIZE * 64)
BOARD_BOOTIMAGE_PARTITION_SIZE := $(extract_variable "boot_a" || echo "")
BOARD_DTBOIMG_PARTITION_SIZE :=  $(extract_variable "dtbo_a" || echo "")
BOARD_RECOVERYIMAGE_PARTITION_SIZE := $(extract_variable "recovery_a" || echo "")
BOARD_INIT_BOOT_IMAGE_PARTITION_SIZE := $(extract_variable "init_boot_a" || echo "")
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := $(extract_variable "vendor_boot_a" || echo "")
BOARD_VENDOR_KERNEL_BOOTIMAGE_PARTITION_SIZE := $(extract_variable "vendor_kernel_boot_a" || echo "")
BOARD_SUPER_PARTITION_SIZE := $(extract_variable "super" || echo "")
BOARD_SUPER_PARTITION_GROUPS := $(echo "${manufacturer}" | tr '[:lower:]' '[:upper:]')_dynamic_partitions
BOARD_$(echo "${manufacturer}" | tr '[:lower:]' '[:upper:]')_DYNAMIC_PARTITIONS_PARTITION_LIST :=
# Platform
TARGET_BOARD_PLATFORM := ${device_codename}

TARGET_PROP := \$(DEVICE_PATH)/system.prop

# Recovery
TARGET_RECOVERY_FSTAB := \$(DEVICE_PATH)/rootdir/etc/fstab.${device_codename}
BOARD_INCLUDE_RECOVERY_DTBO := true
TARGET_RECOVERY_PIXEL_FORMAT := 1080
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true

# Security patch level
VENDOR_SECURITY_PATCH := 2021-09-01

# Verified Boot
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
BOARD_AVB_RECOVERY_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_RECOVERY_ALGORITHM := SHA256_RSA4096
BOARD_AVB_RECOVERY_ROLLBACK_INDEX := 1
BOARD_AVB_RECOVERY_ROLLBACK_INDEX_LOCATION := 1
BOARD_AVB_VENDOR_BOOT_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_VENDOR_BOOT_ALGORITHM := SHA256_RSA4096
BOARD_AVB_VENDOR_BOOT_ROLLBACK_INDEX := 1
BOARD_AVB_VENDOR_BOOT_ROLLBACK_INDEX_LOCATION := 1
BOARD_AVB_VENDOR_KERNEL_BOOT_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_VENDOR_KERNEL_BOOT_ALGORITHM := SHA256_RSA4096
BOARD_AVB_VENDOR_KERNEL_BOOT_ROLLBACK_INDEX := 1
BOARD_AVB_VENDOR_KERNEL_BOOT_ROLLBACK_INDEX_LOCATION := 1

# VINTF
DEVICE_MANIFEST_FILE += \$(DEVICE_PATH)/manifest.xml
mk -p "$DEVICE_MANIFEST_FILE"

# Inherit the proprietary files
include vendor/$(echo "${manufacturer}" | tr '[:lower:]' '[:upper:]')/${device_codename}/BoardConfigVendor.mk
"
    write_properties "$properties" "BoardConfig.mk"
}

# Create Device.mk
create_Device_mk() {
    local device_codename=$(getprop "ro.product.device" || echo "")
    local manufacturer=$(getprop "ro.product.manufacturer" || echo "")
    local board_shipping_api_level=$(getprop "ro.product.first_api_level" || echo "")
    local board_api_level=$(getprop "ro.build.version.sdk" || echo "")
    local first_api_level=$(getprop "ro.product.first_api_level" || echo "")
    local product_characteristics=$(getprop "ro.build.characteristics" || echo "")

    local properties="
# Device.mk

# Inherit from those products. Most specific first.
\$(call inherit-product, \$(SRC_TARGET_DIR)/product/core_64_bit.mk)
\$(call inherit-product, \$(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Inherit some common Lineage stuff.
\$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

# Inherit from ${device_codename} device
\$(call inherit-product, device/${manufacturer}/${device_codename}/device.mk)

PRODUCT_DEVICE := ${device_codename}
PRODUCT_NAME := lineage_${device_codename}
PRODUCT_BRAND := ${manufacturer}
PRODUCT_MODEL := ${device_codename}
PRODUCT_MANUFACTURER := ${manufacturer}

PRODUCT_GMS_CLIENTID_BASE := android-google
PRIVATE_BUILD_DESC := ${manufacturer}-${device_codename}-${board_shipping_api_level}-${board_api_level}
BUILD_FINGERPRINT := ${manufacturer}/${device_codename}/${device_codename}:${first_api_level}/${product_characteristics}

# Partitions
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Rootdir
PRODUCT_PACKAGES += \\
    init \\
    ueventd \\
    fstab.${device_codename}

PRODUCT_COPY_FILES += \\
    \$(LOCAL_PATH)/rootdir/etc/fstab.${device_codename}:\$(TARGET_COPY_OUT_RAMDISK)/fstab.${device_codename}

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \\
    \$(LOCAL_PATH)

# Inherit the proprietary files
\$(call inherit-product, vendor/${manufacturer}/${device_codename}/${device_codename}-vendor.mk)
"

    write_properties "$properties" "Device.mk"
}

# Function to create extract-files.sh script
create_extract_files_sh() {
    # Retrieve device codename and manufacturer from system properties
    local device_codename=$(getprop "ro.product.device" || echo "")
    local manufacturer=$(getprop "ro.product.manufacturer" || echo "")

    # Define the script content using a heredoc for clarity
    local script=$(cat <<-SCRIPT
#!/bin/bash

set -e

DEVICE="${device_codename}"
VENDOR="${manufacturer}"

# Load extract_utils and perform directory sanity checks
MY_DIR="\$PWD"
if [ ! -d "\$MY_DIR" ]; then
    MY_DIR="\$PWD"
fi

ANDROID_ROOT="\$MY_DIR/../../.."

HELPER="\$ANDROID_ROOT/tools/extract-utils/extract_utils.sh"
if [ ! -f $HELPER ]; then
    echo 'Unable to find helper script at "\$HELPER"\'
    exit 1
fi
source "\$HELPER"

# Default to sanitizing the vendor folder before extraction
CLEAN_VENDOR=true

KANG=
SECTION=

# Parse command line arguments
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        -n | --no-cleanup )
            CLEAN_VENDOR=false
            ;;
        -k | --kang )
            KANG="--kang"
            ;;
        -s | --section )
            SECTION="\$2"
            shift
            CLEAN_VENDOR=false
            ;;
        * )
            SRC="\$1"
            ;;
    esac
    shift
done

# Default SRC to "adb" if not provided
if [ -z "\$SRC" ]; then
    SRC="adb"
fi

# Initialize the helper
setup_vendor "\$DEVICE" "\$VENDOR" "\$ANDROID_ROOT" false "\$CLEAN_VENDOR"

# Extract files using parameters
extract "\$MY_DIR/proprietary-files.txt" "\$SRC" "\$KANG" --section "\$SECTION"

# Run setup-makefiles.sh from the current directory
"\$MY_DIR/setup-makefiles.sh"
SCRIPT
)

}

# Create lineage.mk
create_lineage_mk() {
    local device_codename=$(getprop "ro.product.device" || echo "")
    local manufacturer=$(getprop "ro.product.manufacturer" || echo "")
    local brand=$(getprop "ro.product.brand" || echo "")
    local model=$(getprop "ro.product.model" || echo "")
    local gms_clientid_base=$(getprop "ro.com.google.clientidbase" || echo "")
    local build_description=$(getprop "ro.build.description" || echo "")
    local build_fingerprint=$(getprop "ro.build.fingerprint" || echo "")

    local properties="
# Lineage.mk

# Inherit from those products. Most specific first.
\$(call inherit-product, \$(SRC_TARGET_DIR)/product/core_64_bit.mk)
\$(call inherit-product, \$(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Inherit some common Lineage stuff.
\$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

# Inherit from ${device_codename} device
\$(call inherit-product, device/${manufacturer}/${device_codename}/device.mk)

PRODUCT_DEVICE := ${device_codename}
PRODUCT_NAME := lineage_${device_codename}
PRODUCT_BRAND := ${brand}
PRODUCT_MODEL := ${model}
PRODUCT_MANUFACTURER := ${manufacturer}

PRODUCT_GMS_CLIENTID_BASE := ${gms_clientid_base}

PRIVATE_BUILD_DESC := ${build_description}
BUILD_FINGERPRINT := ${build_fingerprint}
"

    write_properties "$properties" "lineage.mk"
}

# Create a backup of the existing output file if it exists
if [ -f "$OUTPUT_FSTAB" ]; then
    cp "$OUTPUT_FSTAB" "$OUTPUT_FSTAB.bak"
fi

# Initialize the output file
echo "# /etc/fstab: static file system information" > "$OUTPUT_FSTAB"
echo "#" >> "$OUTPUT_FSTAB"
echo "# <file system> <mount point> <type> <options> <dump> <pass>" >> "$OUTPUT_FSTAB"
echo "#" >> "$OUTPUT_FSTAB"

# Function to parse fstab entries
parse_fstab() {
    local device_codename=$(getprop "ro.product.device" || echo "")
    local fstab_file="$1"
    while read -r line; do
        # Skip comments and empty lines
        if [[ "$line" == \#* || -z "$line" ]]; then
            continue
        fi

        # Normalize spacing
        line=$(echo "$line" | awk '{$1=$1};1')

        # Extract fields from the line
        fs=$(echo "$line" | awk '{print $1}')
        mount_point=$(echo "$line" | awk '{print $2}')
        type=$(echo "$line" | awk '{print $3}')
        options=$(echo "$line" | awk '{print $4}')
        dump=$(echo "$line" | awk '{print $5}')
        pass=$(echo "$line" | awk '{print $6}')

        # Check if entry already exists in the output file
        if ! grep -q "$fs $mount_point $type" "$OUTPUT_FSTAB"; then
            # Write the entry to the output file
            echo "$fs $mount_point $type $options $dump $pass" >> "$OUTPUT_FSTAB"
        fi
    done < "$fstab_file"
}

# Collect fstab files (common locations)
for fstab_file in /etc/fstab /system/etc/fstab* /vendor/etc/fstab* /product/etc/fstab* /system/product/etc/fstab* /system_ext/etc/fstab* /system/system_ext/etc/fstab*; do
    for file in $fstab_file; do
        if [ -f "$file" ]; then
            echo "Parsing $file"
            parse_fstab "$file"
        fi
    done
done

echo "Generated fstab file at $OUTPUT_FSTAB"

# Function to fetch vendor files from /vendor directory
fetch_vendor_files() {
    local vendor_dir="/vendor"  # Adjust this path according to your environment
    if [ ! -d "$vendor_dir" ]; then
        echo "Vendor directory not found at ${vendor_dir}. Exiting."
        exit 1
    fi

    local vendor_output="$output_dir/rootdir"
    mkdir -p "$vendor_output"

    # Actual copy command to fetch vendor files
    cp -r "$vendor_dir/" "$vendor_output"

    if [ $? -ne 0 ]; then
        echo "Failed to copy vendor files. Exiting."
        exit 1
    fi

    echo "Vendor files copied to: $vendor_output"
}

# Main function
main() {
    # Check and install necessary tools
    check_install_tools

    # Ensure output directory exists
    if [ ! -d "$output_dir" ]; then
        mkdir -p "$output_dir"
        mkdir -p "$output_dir/prebuilts/"
    fi
}

# Function to copy dtbo.img
mkdir -p "$dtbo_output_dir"

# Copy dtbo.img to destination path
copy_dtbo_img () {
    dd if="/dev/block/by-name/dtbo_a" of="/storage/emulated/0/Documents/${device_codename}/prebuilts/dtbo.img"

}

# Function to copy boot.img
copy_boot_img() {
      local device_codename=$(getprop "ro.product.device" || echo "")
      dd if=/dev/block/by-name/boot_a of=/storage/emulated/0/Documents/${device_codename}/prebuilts/boot.img
      if [ $? -ne 0 ]; then
        echo "Failed to copy boot.img to $1"
        exit 1
      fi
      echo "boot.img successfully copied to /storage/emulated/0/Documents/${device_codename}prebuilts/boot.img"

}

# Execute main function
main
create_BoardConfig_mk
create_Device_mk
create_extract_files_sh
create_lineage_mk
# Find device directory
    local device_directory=$(find_device_directory)
    echo "Device directory found: $device_directory"

    # Process .prop files
    process_prop_files "$device_directory"

    # Find or generate build.prop file
    find_or_generate_build_prop

    # Extract ramdisk from boot image
    extract_ramdisk

    # Copy boot.img
    copy_boot_img

    # Fetch vendor files
    fetch_vendor_files

    echo "Universal device tree generation completed successfully."
}

echo "Device tree generation completed" >> "$LOG_FILE"
echo "All files are created in $OUTPUT_DIR and logs are available in $LOG_FILE"
