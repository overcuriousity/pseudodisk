#!/bin/bash

# Forensic Practice Disk Image Creator - Enhanced Version
# Creates disk images with various filesystems for forensic analysis practice
# Now with improved UX, sanity checks, and extended filesystem support

set -e
set -o pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Initialize mount points array to avoid bad-substitution errors when cleanup runs
MOUNT_POINTS=()

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_note() {
    echo -e "${CYAN}[NOTE]${NC} $1"
}

print_tip() {
    echo -e "${MAGENTA}[TIP]${NC} $1"
}

# Filesystem size constraints (in MB)
declare -A FS_MIN_SIZE
FS_MIN_SIZE["fat12"]=1
FS_MIN_SIZE["fat16"]=5
FS_MIN_SIZE["fat32"]=33
FS_MIN_SIZE["exfat"]=1
FS_MIN_SIZE["ntfs"]=7
FS_MIN_SIZE["ext2"]=1
FS_MIN_SIZE["ext3"]=1
FS_MIN_SIZE["ext4"]=1
FS_MIN_SIZE["xfs"]=16
FS_MIN_SIZE["hfsplus"]=8
FS_MIN_SIZE["apfs"]=1
FS_MIN_SIZE["swap"]=1
FS_MIN_SIZE["unallocated"]=1

declare -A FS_MAX_SIZE
FS_MAX_SIZE["fat12"]=16
FS_MAX_SIZE["fat16"]=2048
FS_MAX_SIZE["fat32"]=2097152  # 2TB in theory, but practical limit
FS_MAX_SIZE["exfat"]=16777216  # 16 TB practical
FS_MAX_SIZE["ntfs"]=16777216   # 16 TB+
FS_MAX_SIZE["ext2"]=16777216
FS_MAX_SIZE["ext3"]=16777216
FS_MAX_SIZE["ext4"]=16777216
FS_MAX_SIZE["xfs"]=16777216
FS_MAX_SIZE["hfsplus"]=2097152  # 2TB
FS_MAX_SIZE["apfs"]=16777216
FS_MAX_SIZE["swap"]=128000  # 128GB practical max
FS_MAX_SIZE["unallocated"]=16777216  # No real limit

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to check required tools
check_dependencies() {
    local missing_tools=()
    
    command -v dd >/dev/null 2>&1 || missing_tools+=("coreutils")
    command -v losetup >/dev/null 2>&1 || missing_tools+=("util-linux")
    command -v parted >/dev/null 2>&1 || missing_tools+=("parted")
    command -v bc >/dev/null 2>&1 || missing_tools+=("bc")
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required packages: ${missing_tools[*]}"
        print_info "Install with: sudo apt-get install ${missing_tools[*]}"
        exit 1
    fi
}

# Check filesystem tool availability
check_filesystem_tools() {
    echo ""
    echo "Checking filesystem tool availability..."
    echo ""

    # Each entry: Display Name | space-separated candidate commands | install hint / note
    local checks=(
        "FAT12/16|mkfs.fat mkfs.msdos mkfs.vfat|sudo apt-get install dosfstools"
        "FAT32|mkfs.vfat mkfs.fat|sudo apt-get install dosfstools"
        "exFAT|mkfs.exfat mkfs.exfatprogs mkfs.exfat-utils|sudo apt-get install exfatprogs or exfat-utils"
        "NTFS|mkfs.ntfs mkntfs|sudo apt-get install ntfs-3g"
        "ext2|mkfs.ext2 mke2fs|sudo apt-get install e2fsprogs"
        "ext3|mkfs.ext3 mke2fs|sudo apt-get install e2fsprogs"
        "ext4|mkfs.ext4 mke2fs|sudo apt-get install e2fsprogs"
        "XFS|mkfs.xfs|sudo apt-get install xfsprogs"
        "HFS+|mkfs.hfsplus newfs_hfs|sudo apt-get install hfsprogs"
        "APFS|mkfs.apfs apfs-fuse|limited support — creation typically requires macOS or specialized tools"
        "swap|mkswap|should be present in util-linux"
        "Unallocated|:|no mkfs required"
    )

    local entry name cmds hint cmd found

    for entry in "${checks[@]}"; do
        # Split the packed entry into three fields
        IFS='|' read -r name cmds hint <<< "$entry"
        found=0

        # If cmds is a single colon, treat it as 'no tool required'
        if [ "$cmds" = ":" ]; then
            printf "  %b %s (%s)\n" "${GREEN}✓${NC}" "$name" "$hint"
            continue
        fi

        # Check each candidate command for the filesystem
        for cmd in $cmds; do
            if command -v "$cmd" >/dev/null 2>&1; then
                printf "  %b %-12s (%s available)\n" "${GREEN}✓${NC}" "$name" "$cmd"
                found=1
                break
            fi
        done

        if [ "$found" -eq 0 ]; then
            printf "  %b %-12s (install: %s)\n" "${YELLOW}✗${NC}" "$name" "$hint"
        fi
    done

    echo ""
}

# Validate filesystem label
validate_label() {
    local fs=$1
    local label=$2
    
    case $fs in
        fat12|fat16|fat32|vfat)
            if [ ${#label} -gt 11 ]; then
                print_error "FAT label must be 11 characters or less"
                return 1
            fi
            # FAT labels should be uppercase and no lowercase allowed
            if [[ "$label" =~ [a-z] ]]; then
                print_warning "FAT labels are typically uppercase. Converting..."
                echo "${label^^}"
                return 0
            fi
            ;;
        ntfs)
            if [ ${#label} -gt 32 ]; then
                print_error "NTFS label must be 32 characters or less"
                return 1
            fi
            ;;
        ext2|ext3|ext4)
            if [ ${#label} -gt 16 ]; then
                print_error "ext2/3/4 label must be 16 characters or less"
                return 1
            fi
            ;;
        xfs)
            if [ ${#label} -gt 12 ]; then
                print_error "XFS label must be 12 characters or less"
                return 1
            fi
            ;;
        exfat)
            if [ ${#label} -gt 15 ]; then
                print_error "exFAT label must be 15 characters or less"
                return 1
            fi
            ;;
        hfsplus)
            if [ ${#label} -gt 27 ]; then
                print_error "HFS+ label must be 27 characters or less"
                return 1
            fi
            ;;
    esac
    
    echo "$label"
    return 0
}

# Check if size is appropriate for filesystem
validate_fs_size() {
    local fs=$1
    local size=$2
    
    if [ "$size" = "remaining" ]; then
        return 0
    fi
    
    local min=${FS_MIN_SIZE[$fs]}
    local max=${FS_MAX_SIZE[$fs]}
    
    if [ -n "$min" ] && [ "$size" -lt "$min" ]; then
        print_error "Partition size ${size}MB is too small for $fs (minimum: ${min}MB)"
        return 1
    fi
    
    if [ -n "$max" ] && [ "$size" -gt "$max" ]; then
        print_warning "Partition size ${size}MB exceeds recommended maximum for $fs (${max}MB)"
        read -p "Continue anyway? (y/n): " continue
        if [ "$continue" != "y" ]; then
            return 1
        fi
    fi
    
    # Specific warnings
    case $fs in
        fat12)
            if [ "$size" -gt 16 ]; then
                print_error "FAT12 cannot exceed 16MB"
                return 1
            fi
            ;;
        fat16)
            if [ "$size" -lt 16 ]; then
                print_warning "Partition is small enough for FAT12, but you selected FAT16"
            fi
            if [ "$size" -gt 2048 ]; then
                print_error "FAT16 cannot exceed 2GB (2048MB)"
                return 1
            fi
            ;;
        fat32)
            if [ "$size" -lt 33 ]; then
                print_error "FAT32 requires at least 33MB"
                return 1
            fi
            ;;
        xfs)
            if [ "$size" -lt 16 ]; then
                print_error "XFS requires at least 16MB"
                return 1
            fi
            ;;
    esac
    
    return 0
}

# Display banner
show_banner() {
    echo ""
    echo "=========================================="
    echo "  Forensic Disk Image Creator"
    echo "  Enhanced Edition v2.1"
    echo "=========================================="
    echo ""
}

# Get filename from user
get_filename() {
    echo ""
    read -p "Enter output filename (default: forensic_disk.dd): " FILENAME
    FILENAME=${FILENAME:-forensic_disk.dd}

    # Strip whitespace
    FILENAME=$(echo "$FILENAME" | xargs)

    # Reject invalid characters (allow only safe chars)
    if [[ ! "$FILENAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "Filename can only contain: letters, numbers, dots, underscores, hyphens"
        get_filename
        return
    fi

    # Prevent path traversal and absolute paths
    if [[ "$FILENAME" == *".."* ]] || [[ "$FILENAME" == /* ]]; then
        print_error "Path traversal not allowed"
        get_filename
        return
    fi

    # Ensure .dd extension
    if [[ "$FILENAME" != *.dd ]]; then
        FILENAME="${FILENAME}.dd"
        print_info "Added .dd extension: $FILENAME"
    fi

    # Check if file exists
    if [ -f "$FILENAME" ]; then
        print_warning "File already exists: $FILENAME"
        read -p "Overwrite? (y/n): " OVERWRITE
        if [ "$OVERWRITE" != "y" ]; then
            print_info "Please choose a different filename"
            get_filename
            return
        fi
    fi
}

# Get disk size from user
get_disk_size() {
    echo ""
    echo "Disk Size Options:"
    echo "  1) 100 MB   (small, quick testing)"
    echo "  2) 500 MB   (medium)"
    echo "  3) 1 GB     (standard)"
    echo "  4) 5 GB     (large)"
    echo "  5) 10 GB    (very large)"
    echo "  6) Custom size"
    echo ""
    read -p "Select disk size [1-6]: " SIZE_CHOICE

    case $SIZE_CHOICE in
        1) DISK_SIZE_MB=100 ;;
        2) DISK_SIZE_MB=500 ;;
        3) DISK_SIZE_MB=1024 ;;
        4) DISK_SIZE_MB=5120 ;;
        5) DISK_SIZE_MB=10240 ;;
        6)
            while true; do
                read -p "Enter size in MB: " DISK_SIZE_MB

                # Validate input
                if ! [[ "$DISK_SIZE_MB" =~ ^[0-9]+$ ]]; then
                    print_error "Invalid input. Enter a number."
                    continue
                fi

                if [ "$DISK_SIZE_MB" -lt 10 ]; then
                    print_error "Minimum size is 10 MB"
                    continue
                fi

                # Maximum 10TB (reasonable limit)
                if [ "$DISK_SIZE_MB" -gt 10485760 ]; then
                    print_error "Maximum size is 10TB (10485760 MB)"
                    continue
                fi

                # Check available disk space
                local available_kb
                available_kb=$(df --output=avail -k "." | tail -1)
                local required_kb=$((DISK_SIZE_MB * 1024))

                if [ "$available_kb" -lt "$required_kb" ]; then
                    local available_mb=$((available_kb / 1024))
                    print_error "Not enough disk space. Available: ${available_mb}MB"
                    continue
                fi

                break
            done
            ;;
        *)
            print_error "Invalid choice"
            get_disk_size
            return
            ;;
    esac

    print_info "Selected disk size: ${DISK_SIZE_MB} MB ($(echo "scale=2; $DISK_SIZE_MB/1024" | bc) GB)"
}

# Get initialization method
get_init_method() {
    echo ""
    echo "Initialization Method:"
    echo "  1) /dev/zero   (Fast, zeros - forensically predictable)"
    echo "  2) /dev/urandom (Slow, random data - more realistic)"
    echo "  3) fallocate   (Fastest, sparse file - testing only)"
    echo ""
    print_tip "For forensic practice, /dev/zero (option 1) is recommended"
    echo ""
    read -p "Select initialization method [1-3]: " INIT_CHOICE
    
    case $INIT_CHOICE in
        1) INIT_METHOD="zero" ;;
        2) 
            INIT_METHOD="random"
            print_warning "Random initialization can be VERY slow for large disks"
            estimated_time=$(echo "scale=0; $DISK_SIZE_MB/10" | bc)
            print_info "Estimated time: ~${estimated_time} seconds"
            ;;
        3) 
            INIT_METHOD="fallocate"
            print_warning "Sparse files may not be suitable for all forensic scenarios"
            ;;
        *)
            print_error "Invalid choice"
            get_init_method
            return
            ;;
    esac
    
    print_info "Selected initialization method: $INIT_METHOD"
}

# Get preset or custom layout
get_preset_or_custom() {
    USE_PRESET=false
    
    echo ""
    echo "=========================================="
    echo "  Disk Layout"
    echo "=========================================="
    echo ""
    echo "Layout Presets:"
    echo ""
    echo "  Windows Presets:"
    echo "    1)  Windows 11/10 (GPT, EFI + NTFS + Recovery)"
    echo "    2)  Windows Vista/7/8 (MBR, System Reserved + NTFS)"
    echo "    3)  Windows 2000/XP (MBR, Single NTFS)"
    echo "    4)  Windows 98/ME (MBR, Single FAT32)"
    echo "    5)  Windows 95 (MBR, Single FAT16)"
    echo "    6)  Windows 3.1 (MBR, Single FAT16)"
    echo "    7)  MS-DOS (MBR, Single FAT12)"
    echo ""
    echo "  Linux Presets:"
    echo "    8)  Modern Linux (GPT, EFI + Root + Swap)"
    echo "    9)  Linux with /home (GPT, EFI + Root + Home)"
    echo "    10) Classic Linux (MBR, Boot + Root + Swap)"
    echo "    11) Minimal Linux (MBR, Single ext4)"
    echo ""
    echo "  macOS Presets:"
    echo "    12) Modern macOS (GPT, EFI + APFS)"
    echo "    13) Legacy macOS (GPT, Single HFS+)"
    echo ""
    echo "  Custom:"
    echo "    14) Custom layout (manual configuration)"
    echo ""
    read -p "Select layout [1-14]: " PRESET_CHOICE
    
    case $PRESET_CHOICE in
        1)  # Windows 11/10
            USE_PRESET=true
            PARTITION_SCHEME="gpt"
            PARTITION_COUNT=3
            print_info "Preset: Windows 11/10 (GPT)"
            print_note "EFI System Partition (260MB) + Main Windows (auto) + Recovery (500MB)"
            ;;
        2)  # Windows Vista/7/8
            USE_PRESET=true
            PARTITION_SCHEME="msdos"
            PARTITION_COUNT=2
            print_info "Preset: Windows Vista/7/8 (MBR)"
            print_note "System Reserved (100MB) + Main Windows (auto)"
            ;;
        3)  # Windows 2000/XP
            USE_PRESET=true
            PARTITION_SCHEME="msdos"
            PARTITION_COUNT=1
            print_info "Preset: Windows 2000/XP (MBR)"
            print_note "Single NTFS partition"
            ;;
        4)  # Windows 98/ME
            USE_PRESET=true
            PARTITION_SCHEME="msdos"
            PARTITION_COUNT=1
            print_info "Preset: Windows 98/ME (MBR)"
            print_note "Single FAT32 partition"
            ;;
        5)  # Windows 95
            USE_PRESET=true
            PARTITION_SCHEME="msdos"
            PARTITION_COUNT=1
            print_info "Preset: Windows 95 (MBR)"
            print_note "Single FAT16 partition"
            ;;
        6)  # Windows 3.1
            USE_PRESET=true
            PARTITION_SCHEME="msdos"
            PARTITION_COUNT=1
            print_info "Preset: Windows 3.1 (MBR)"
            print_note "Single FAT16 partition"
            ;;
        7)  # MS-DOS
            USE_PRESET=true
            PARTITION_SCHEME="msdos"
            PARTITION_COUNT=1
            print_info "Preset: MS-DOS (MBR)"
            print_note "Single FAT12 partition"
            if [ "$DISK_SIZE_MB" -gt 16 ]; then
                print_warning "MS-DOS typically uses FAT12 which is limited to 16MB"
                print_info "Consider reducing disk size or the partition will use FAT16"
            fi
            ;;
        8)  # Modern Linux
            USE_PRESET=true
            PARTITION_SCHEME="gpt"
            PARTITION_COUNT=3
            print_info "Preset: Modern Linux (GPT)"
            print_note "EFI (260MB) + Root ext4 (auto) + Swap (2GB)"
            ;;
        9)  # Linux with /home
            USE_PRESET=true
            PARTITION_SCHEME="gpt"
            PARTITION_COUNT=3
            print_info "Preset: Linux with separate /home (GPT)"
            print_note "EFI (260MB) + Root ext4 (auto) + Home ext4 (auto)"
            ;;
        10) # Classic Linux
            USE_PRESET=true
            PARTITION_SCHEME="msdos"
            PARTITION_COUNT=3
            print_info "Preset: Classic Linux (MBR)"
            print_note "Boot ext4 (500MB) + Root ext4 (auto) + Swap (2GB)"
            ;;
        11) # Minimal Linux
            USE_PRESET=true
            PARTITION_SCHEME="msdos"
            PARTITION_COUNT=1
            print_info "Preset: Minimal Linux (MBR)"
            print_note "Single ext4 partition"
            ;;
        12) # Modern macOS
            USE_PRESET=true
            PARTITION_SCHEME="gpt"
            PARTITION_COUNT=2
            print_info "Preset: Modern macOS (GPT)"
            print_note "EFI (200MB) + APFS (auto)"
            print_warning "APFS support on Linux is very limited"
            ;;
        13) # Legacy macOS
            USE_PRESET=true
            PARTITION_SCHEME="gpt"
            PARTITION_COUNT=1
            print_info "Preset: Legacy macOS (GPT)"
            print_note "Single HFS+ partition"
            print_warning "HFS+ support on Linux is limited"
            ;;
        14) # Custom
            USE_PRESET=false
            print_info "Custom layout selected"
            ;;
        *)
            print_error "Invalid choice"
            get_preset_or_custom
            return
            ;;
    esac
    
    if [ "$USE_PRESET" = true ]; then
        echo ""
        read -p "Customize this preset? (y/n, default: n): " CUSTOMIZE
        CUSTOMIZE=${CUSTOMIZE:-n}
        
        if [ "$CUSTOMIZE" = "y" ]; then
            ALLOW_PRESET_CUSTOMIZATION=true
            print_info "You can modify the preset configuration in the next steps"
        else
            ALLOW_PRESET_CUSTOMIZATION=false
            print_info "Using preset configuration as-is"
        fi
    fi
}

# Apply preset configuration
apply_preset() {
    PARTITION_CONFIGS=()

    case $PRESET_CHOICE in
        1)  # Windows 11/10
            PARTITION_CONFIGS+=("vfat|260|EFI")
            PARTITION_CONFIGS+=("ntfs|remaining|Windows")
            PARTITION_CONFIGS+=("ntfs|500|Recovery")
            ;;
        2)  # Windows Vista/7/8
            PARTITION_CONFIGS+=("ntfs|100|System")
            PARTITION_CONFIGS+=("ntfs|remaining|Windows")
            ;;
        3)  # Windows 2000/XP
            PARTITION_CONFIGS+=("ntfs|remaining|Windows")
            ;;
        4)  # Windows 98/ME
            PARTITION_CONFIGS+=("vfat|remaining|WIN98")
            ;;
        5)  # Windows 95
            if [ "$DISK_SIZE_MB" -le 2048 ]; then
                PARTITION_CONFIGS+=("fat16|remaining|WIN95")
            else
                PARTITION_CONFIGS+=("vfat|remaining|WIN95")
                print_warning "Disk >2GB, using FAT32 instead of FAT16"
            fi
            ;;
        6)  # Windows 3.1
            PARTITION_CONFIGS+=("fat16|remaining|WIN31")
            ;;
        7)  # MS-DOS
            if [ "$DISK_SIZE_MB" -le 16 ]; then
                PARTITION_CONFIGS+=("fat12|remaining|MSDOS")
            else
                PARTITION_CONFIGS+=("fat16|remaining|MSDOS")
                print_warning "Disk >16MB, using FAT16 instead of FAT12"
            fi
            ;;
        8)  # Modern Linux
            PARTITION_CONFIGS+=("vfat|260|EFI")
            PARTITION_CONFIGS+=("ext4|remaining|rootfs")
            PARTITION_CONFIGS+=("swap|2048|")
            ;;
        9)  # Linux with /home
            local root_size=$((DISK_SIZE_MB / 4))
            local min_root=5120

            if [ "$root_size" -lt "$min_root" ]; then
                # Check if disk is large enough for minimum
                if [ "$DISK_SIZE_MB" -lt "$((min_root + 1024))" ]; then
                    # Disk too small, use proportional sizing
                    root_size=$((DISK_SIZE_MB * 2 / 3))
                    print_warning "Disk too small for 5GB root, using ${root_size}MB"
                else
                    root_size=$min_root
                fi
            fi

            PARTITION_CONFIGS+=("vfat|260|EFI")
            PARTITION_CONFIGS+=("ext4|${root_size}|rootfs")
            PARTITION_CONFIGS+=("ext4|remaining|home")
            ;;
        10) # Classic Linux
            PARTITION_CONFIGS+=("ext4|500|boot")
            PARTITION_CONFIGS+=("ext4|remaining|rootfs")
            PARTITION_CONFIGS+=("swap|2048|")
            ;;
        11) # Minimal Linux
            PARTITION_CONFIGS+=("ext4|remaining|rootfs")
            ;;
        12) # Modern macOS
            PARTITION_CONFIGS+=("vfat|200|EFI")
            PARTITION_CONFIGS+=("apfs|remaining|MacintoshHD")
            ;;
        13) # Legacy macOS
            PARTITION_CONFIGS+=("hfsplus|remaining|MacintoshHD")
            ;;
    esac
}

# Get partition scheme
get_partition_scheme() {
    echo ""
    echo "Partition Scheme:"
    echo "  1) GPT (GUID Partition Table) - Modern, Windows 10/11 default"
    echo "  2) MBR (Master Boot Record) - Legacy, compatible with older systems"
    echo ""
    print_tip "GPT is recommended for modern systems and disks >2TB"
    echo ""
    read -p "Select partition scheme [1-2]: " PARTITION_CHOICE_SCHEME
    
    case $PARTITION_CHOICE_SCHEME in
        1) PARTITION_SCHEME="gpt" ;;
        2) 
            PARTITION_SCHEME="msdos"
            if [ "$DISK_SIZE_MB" -gt 2097152 ]; then
                print_error "MBR does not support disks larger than 2TB"
                print_info "Please select GPT or reduce disk size"
                get_partition_scheme
                return
            fi
            ;;
        *)
            print_error "Invalid choice"
            get_partition_scheme
            return
            ;;
    esac
    
    print_info "Selected partition scheme: $PARTITION_SCHEME"
}

# Get number of partitions
get_partition_count() {
    echo ""
    read -p "How many partitions? (1-4): " PARTITION_COUNT
    
    if ! [[ "$PARTITION_COUNT" =~ ^[1-4]$ ]]; then
        print_error "Invalid number. Must be between 1 and 4"
        get_partition_count
        return
    fi
    
    if [ "$PARTITION_COUNT" -gt 1 ]; then
        print_note "The last partition will automatically use all remaining space"
    fi
    
    print_info "Creating $PARTITION_COUNT partition(s)"
}

# Get partition configurations
get_partition_configs() {
    PARTITION_CONFIGS=()
    local total_allocated=0
    local available_space=$((DISK_SIZE_MB - PARTITION_TABLE_RESERVED_MB))  # Reserve for partition table / metadata
    
    for i in $(seq 1 $PARTITION_COUNT); do
        echo ""
        echo "=========================================="
        echo "  Partition $i Configuration"
        echo "=========================================="
        
        if [ $i -gt 1 ]; then
            print_info "Available space: ${available_space}MB"
        fi
        
        # Get filesystem
        echo ""
        echo "Filesystem Type:"
        echo "  1)  FAT12   (Very small, <16MB, legacy)"
        echo "  2)  FAT16   (Small, 16MB-2GB, legacy)"
        echo "  3)  FAT32   (Universal, 32MB+, good compatibility)"
        echo "  4)  exFAT   (Modern, large files, cross-platform)"
        echo "  5)  NTFS    (Windows default, journaling)"
        echo "  6)  ext2    (Linux legacy, no journaling)"
        echo "  7)  ext3    (Linux, journaling)"
        echo "  8)  ext4    (Linux default, modern)"
        echo "  9)  XFS     (High-performance Linux)"
        echo "  10) HFS+    (macOS legacy)"
        echo "  11) APFS    (macOS modern - limited Linux support)"
        echo "  12) swap    (Linux swap space)"
        echo "  13) unallocated (Empty space - for forensic practice)"
        echo ""
        read -p "Select filesystem for partition $i [1-13]: " FS_CHOICE
        
        case $FS_CHOICE in
            1) 
                PART_FS="fat12"
                if ! command -v mkfs.fat >/dev/null 2>&1; then
                    print_error "mkfs.fat not found. Install: sudo apt-get install dosfstools"
                    get_partition_configs
                    return
                fi
                print_note "FAT12 is limited to <16MB partitions"
                ;;
            2) 
                PART_FS="fat16"
                if ! command -v mkfs.fat >/dev/null 2>&1; then
                    print_error "mkfs.fat not found. Install: sudo apt-get install dosfstools"
                    get_partition_configs
                    return
                fi
                print_note "FAT16 is limited to 16MB-2GB partitions"
                ;;
            3) 
                PART_FS="vfat"
                if ! command -v mkfs.vfat >/dev/null 2>&1; then
                    print_error "mkfs.vfat not found. Install: sudo apt-get install dosfstools"
                    get_partition_configs
                    return
                fi
                ;;
            4) 
                PART_FS="exfat"
                if ! command -v mkfs.exfat >/dev/null 2>&1; then
                    print_error "mkfs.exfat not found. Install: sudo apt-get install exfatprogs"
                    get_partition_configs
                    return
                fi
                ;;
            5) 
                PART_FS="ntfs"
                if ! command -v mkfs.ntfs >/dev/null 2>&1; then
                    print_error "mkfs.ntfs not found. Install: sudo apt-get install ntfs-3g"
                    get_partition_configs
                    return
                fi
                ;;
            6) 
                PART_FS="ext2"
                if ! command -v mkfs.ext2 >/dev/null 2>&1; then
                    print_error "mkfs.ext2 not found. Install: sudo apt-get install e2fsprogs"
                    get_partition_configs
                    return
                fi
                print_note "ext2 has no journaling - faster but less crash-resistant"
                ;;
            7) 
                PART_FS="ext3"
                if ! command -v mkfs.ext3 >/dev/null 2>&1; then
                    print_error "mkfs.ext3 not found. Install: sudo apt-get install e2fsprogs"
                    get_partition_configs
                    return
                fi
                ;;
            8) 
                PART_FS="ext4"
                if ! command -v mkfs.ext4 >/dev/null 2>&1; then
                    print_error "mkfs.ext4 not found. Install: sudo apt-get install e2fsprogs"
                    get_partition_configs
                    return
                fi
                ;;
            9) 
                PART_FS="xfs"
                if ! command -v mkfs.xfs >/dev/null 2>&1; then
                    print_error "mkfs.xfs not found. Install: sudo apt-get install xfsprogs"
                    get_partition_configs
                    return
                fi
                print_note "XFS requires at least 16MB"
                ;;
            10)
                PART_FS="hfsplus"
                if ! command -v mkfs.hfsplus >/dev/null 2>&1; then
                    print_error "mkfs.hfsplus not found. Install: sudo apt-get install hfsprogs"
                    get_partition_configs
                    return
                fi
                print_warning "HFS+ support on Linux is limited"
                ;;
            11)
                PART_FS="apfs"
                print_warning "APFS has very limited Linux support and may not work properly"
                read -p "Continue anyway? (y/n): " continue
                if [ "$continue" != "y" ]; then
                    get_partition_configs
                    return
                fi
                ;;
            12)
                PART_FS="swap"
                if ! command -v mkswap >/dev/null 2>&1; then
                    print_error "mkswap not found. Install: sudo apt-get install util-linux"
                    get_partition_configs
                    return
                fi
                ;;
            13)
                PART_FS="unallocated"
                print_note "Unallocated space - useful for practicing partition recovery"
                ;;
            *)
                print_error "Invalid choice"
                get_partition_configs
                return
                ;;
        esac
        
        # Get size
        if [ $i -lt $PARTITION_COUNT ]; then
            while true; do
                if [ $i -eq $((PARTITION_COUNT - 1)) ]; then
                    # Second to last partition - show what will be left
                    print_tip "Press Enter to use remaining space (${available_space}MB) or specify size"
                    read -p "Size for partition $i in MB (default: remaining): " PART_SIZE
                else
                    read -p "Size for partition $i in MB: " PART_SIZE
                fi
                
                # Handle default to remaining space
                if [ -z "$PART_SIZE" ] && [ $i -eq $((PARTITION_COUNT - 1)) ]; then
                    PART_SIZE="remaining"
                    print_info "Partition $i will use remaining space (~${available_space}MB)"
                    
                    # Validate remaining space for filesystem
                    if ! validate_fs_size "$PART_FS" "$available_space"; then
                        print_error "Remaining space (${available_space}MB) is not suitable for $PART_FS"
                        continue
                    fi
                    break
                fi
                
                if ! [[ "$PART_SIZE" =~ ^[0-9]+$ ]] || [ "$PART_SIZE" -lt 1 ]; then
                    print_error "Invalid size. Enter a number or press Enter for remaining space"
                    continue
                fi
                
                # Validate size for filesystem
                if ! validate_fs_size "$PART_FS" "$PART_SIZE"; then
                    continue
                fi
                
                # Check if size exceeds available space
                if [ "$PART_SIZE" -ge "$available_space" ]; then
                    print_error "Not enough space. Available: ${available_space}MB"
                    continue
                fi
                
                # Leave at least 10MB for the last partition
                if [ $i -eq $((PARTITION_COUNT - 1)) ]; then
                    remaining=$((available_space - PART_SIZE))
                    if [ "$remaining" -lt 10 ]; then
                        print_error "Not enough space left for last partition (need at least 10MB)"
                        print_tip "Press Enter to use remaining ${available_space}MB instead"
                        continue
                    fi
                fi
                
                break
            done
            
            if [ "$PART_SIZE" != "remaining" ]; then
                total_allocated=$((total_allocated + PART_SIZE))
                available_space=$((available_space - PART_SIZE))
            fi
        else
            PART_SIZE="remaining"
            print_info "Partition $i will use remaining space (~${available_space}MB)"
            
            # Validate remaining space for filesystem
            if ! validate_fs_size "$PART_FS" "$available_space"; then
                print_error "Remaining space (${available_space}MB) is not suitable for $PART_FS"
                get_partition_configs
                return
            fi
        fi
        
        # Get label (skip for swap and unallocated)
        if [ "$PART_FS" != "swap" ] && [ "$PART_FS" != "unallocated" ]; then
            while true; do
                read -p "Volume label for partition $i (default: PART$i): " PART_LABEL
                PART_LABEL=${PART_LABEL:-PART$i}
                
                # Validate label
                validated_label=$(validate_label "$PART_FS" "$PART_LABEL")
                if [ $? -eq 0 ]; then
                    PART_LABEL="$validated_label"
                    break
                fi
            done
        else
            PART_LABEL=""
        fi
        
        PARTITION_CONFIGS+=("$PART_FS|$PART_SIZE|$PART_LABEL")
        
        if [ "$PART_FS" = "swap" ]; then
            print_info "Partition $i: $PART_FS, ${PART_SIZE}MB"
        elif [ "$PART_FS" = "unallocated" ]; then
            print_info "Partition $i: $PART_FS, ${PART_SIZE}MB (no filesystem)"
        else
            print_info "Partition $i: $PART_FS, ${PART_SIZE}MB, label='$PART_LABEL'"
        fi
    done
    
    # Final sanity check
    if [ "$total_allocated" -gt "$((DISK_SIZE_MB - 10))" ]; then
        print_warning "Partitions use almost all disk space. This may cause issues."
    fi
}

# Create the disk image
create_disk_image() {
    print_info "Creating disk image file: $FILENAME (${DISK_SIZE_MB} MB) using $INIT_METHOD..."

    case $INIT_METHOD in
        fallocate)
            if command -v fallocate >/dev/null 2>&1; then
                if ! fallocate -l ${DISK_SIZE_MB}M "$FILENAME"; then
                    print_error "Failed to create disk image with fallocate"
                    exit 1
                fi
            else
                print_warning "fallocate not available, falling back to /dev/zero"
                if ! dd if=/dev/zero of="$FILENAME" bs=1M count="$DISK_SIZE_MB" status=progress; then
                    print_error "Failed to create disk image"
                    exit 1
                fi
            fi
            ;;
        zero)
            if ! dd if=/dev/zero of="$FILENAME" bs=1M count="$DISK_SIZE_MB" status=progress; then
                print_error "Failed to create disk image"
                exit 1
            fi
            ;;
        random)
            print_warning "Using /dev/urandom - this will be SLOW!"
            if ! dd if=/dev/urandom of="$FILENAME" bs=1M count="$DISK_SIZE_MB" status=progress; then
                print_error "Failed to create disk image"
                exit 1
            fi
            ;;
    esac

    # Verify file was created with correct size
    if [ ! -f "$FILENAME" ]; then
        print_error "Disk image file was not created"
        exit 1
    fi

    local actual_size
    actual_size=$(stat -c%s "$FILENAME" 2>/dev/null || stat -f%z "$FILENAME" 2>/dev/null || echo 0)
    local expected_size=$((DISK_SIZE_MB * 1024 * 1024))

    if [ "$actual_size" -ne "$expected_size" ]; then
        print_error "Disk image size mismatch (expected ${expected_size} bytes, got ${actual_size})"
        rm -f "$FILENAME"
        exit 1
    fi

    print_success "Disk image created and verified"
}

# Setup loop device
setup_loop_device() {
    print_info "Setting up loop device..."

    # Try to attach the image and ask the kernel to create partition devices (-P) when supported.
    # Fall back to a plain attach if -P is not available.
    LOOP_DEVICE=$(losetup -f --show -P "$FILENAME" 2>/dev/null || true)

    if [ -z "$LOOP_DEVICE" ]; then
        # older losetup may not support -P; attach without it then trigger partprobe later
        LOOP_DEVICE=$(losetup -f --show "$FILENAME" 2>/dev/null || true)
    fi

    if [ -z "$LOOP_DEVICE" ]; then
        print_error "Failed to create loop device"
        print_info "Try: sudo modprobe loop max_loop=16"
        exit 1
    fi

    print_success "Loop device created: $LOOP_DEVICE"
}

# Create partition table and partitions
create_partitions() {
    print_info "Creating $PARTITION_SCHEME partition table..."

    parted -s "$LOOP_DEVICE" mklabel "$PARTITION_SCHEME"

    # Reserve a small margin at the end of the disk to avoid creating partitions that
    # extend into GPT backup header / metadata. This mirrors the -2MB reserve used
    # interactively elsewhere in the script.
    local PARTITION_TABLE_RESERVED_MB=2
    if [ "$DISK_SIZE_MB" -le $PARTITION_TABLE_RESERVED_MB ]; then
        print_error "Disk size (${DISK_SIZE_MB}MB) too small to reserve required metadata space"
        cleanup
        exit 1
    fi

    local usable_mb=$((DISK_SIZE_MB - PARTITION_TABLE_RESERVED_MB))

    # Parse PARTITION_CONFIGS into arrays for easier processing
    local fs size label
    local -a fs_arr size_arr label_arr
    for config in "${PARTITION_CONFIGS[@]}"; do
        IFS='|' read -r fs size label <<< "$config"
        fs_arr+=("$fs")
        size_arr+=("$size")
        label_arr+=("$label")
    done

    local count=${#fs_arr[@]}
    if [ "$count" -eq 0 ]; then
        print_info "No partition configurations provided"
        return
    fi

    # Convert sizes: numeric values stay numeric; 'remaining' will be resolved below
    local -a numeric_size
    local total_fixed=0
    local -a remaining_idxs
    for i in $(seq 0 $((count - 1))); do
        s="${size_arr[$i]}"
        if [ "$s" = "remaining" ]; then
            numeric_size[$i]=-1
            remaining_idxs+=("$i")
        else
            # sanitize numeric sizes (should be integer MB)
            if ! [[ "$s" =~ ^[0-9]+$ ]]; then
                print_error "Invalid partition size for entry $((i+1)): '$s'"
                cleanup
                exit 1
            fi
            numeric_size[$i]=$s
            total_fixed=$((total_fixed + s))
        fi
    done

    # Distribute remaining space among 'remaining' entries using the usable space
    if [ "${#remaining_idxs[@]}" -gt 0 ]; then
        local free_space=$((usable_mb - total_fixed))
        if [ "$free_space" -le 0 ]; then
            print_error "Not enough space to satisfy 'remaining' partitions (free: ${free_space}MB)"
            cleanup
            exit 1
        fi

        local rem_count=${#remaining_idxs[@]}
        local base=$((free_space / rem_count))
        local leftover=$((free_space - base * rem_count))

        for idx in "${remaining_idxs[@]}"; do
            numeric_size[$idx]=$base
            if [ "$leftover" -gt 0 ]; then
                numeric_size[$idx]=$((numeric_size[$idx] + 1))
                leftover=$((leftover - 1))
            fi
        done
    fi

    # Find last index that will actually produce a partition entry (skip 'unallocated')
    local last_mkpart_idx=-1
    for i in $(seq 0 $((count - 1))); do
        if [ "${fs_arr[$i]}" != "unallocated" ]; then
            last_mkpart_idx=$i
        fi
    done

    # If everything is unallocated, nothing to do
    if [ "$last_mkpart_idx" -eq -1 ]; then
        print_info "All configured space is unallocated - no partition entries will be created"
        return
    fi

    # Compute how much explicit unallocated space is trailing after the last mkpart so we can reserve it
    local trailing_unalloc_sum=0
    for i in $(seq $((last_mkpart_idx + 1)) $((count - 1))); do
        if [ "$i" -ge 0 ] && [ "${fs_arr[$i]}" = "unallocated" ]; then
            trailing_unalloc_sum=$((trailing_unalloc_sum + numeric_size[$i]))
        fi
    done

    # Sanity checks: ensure no numeric sizes are negative and the requested layout fits within usable space
    local sum_all=0
    for i in $(seq 0 $((count - 1))); do
        if [ -z "${numeric_size[$i]}" ] || [ "${numeric_size[$i]}" -lt 0 ]; then
            print_error "Internal error: unresolved partition size for entry $((i+1))"
            cleanup
            exit 1
        fi
        sum_all=$((sum_all + numeric_size[$i]))
    done

    if [ "$sum_all" -gt "$usable_mb" ]; then
        print_error "Configured partitions (${sum_all}MB) exceed usable disk space (${usable_mb}MB) (reserved ${PARTITION_TABLE_RESERVED_MB}MB for metadata)"
        cleanup
        exit 1
    fi

    # Create partitions. We'll iterate in forward order, but the last mkpart will be explicitly ended
    # before any trailing unallocated space so that 'unallocated' regions remain as requested.
    local start_mb=1
    local part_num=1

    # Attempt to create a partition, retrying with shrinking end boundary when parted
    # complains the end is outside the device (handles alignment/metadata rounding)
    try_mkpart() {
        local loopdev="$1"
        local start_mb="$2"
        local end_mb="$3"   # numeric MB
        local fstype="$4"   # optional parted fs type (e.g. ntfs, ext4)

        local max_attempts=8
        local attempt_end=$end_mb
        local output ret last_output

        for ((try=0; try<max_attempts; try++)); do
            local end_str="${attempt_end}MiB"

            if [ -n "$fstype" ]; then
                output=$(parted -s "$loopdev" mkpart primary "$fstype" "${start_mb}MiB" "$end_str" 2>&1)
                ret=$?
            else
                output=$(parted -s "$loopdev" mkpart primary "${start_mb}MiB" "$end_str" 2>&1)
                ret=$?
            fi

            if [ $ret -eq 0 ]; then
                return 0
            fi

            last_output="$output"

            # If the error looks like 'outside device' / 'not enough space' try shrinking the end
            if echo "$output" | grep -Ei 'outside|out of range|not enough space|beyond|außerhalb|außer' >/dev/null 2>&1; then
                print_warning "parted failed to create partition with end ${end_str} - retrying with ${attempt_end-1}MiB: $output"
                attempt_end=$((attempt_end - 1))

                if [ "$attempt_end" -le "$start_mb" ]; then
                    print_error "Cannot allocate partition: insufficient space after retries"
                    echo "$last_output"
                    cleanup
                    exit 1
                fi

                continue
            else
                print_error "parted failed creating partition: $output"
                cleanup
                exit 1
            fi
        done

        print_error "Failed to create partition after ${max_attempts} retries: $last_output"
        cleanup
        exit 1
    }

    for i in $(seq 0 $((count - 1))); do
        fs="${fs_arr[$i]}"
        size_mb=${numeric_size[$i]}
        label="${label_arr[$i]}"

        if [ "$fs" = "unallocated" ]; then
            print_info "Leaving ${size_mb}MB unallocated (no partition entry)"
            start_mb=$((start_mb + size_mb))
            continue
        fi

        # determine end for this partition
        if [ "$i" -eq "$last_mkpart_idx" ]; then
            # Make sure last mkpart ends before any trailing unallocated space and within usable area
            end_mb=$((usable_mb - trailing_unalloc_sum))
            if [ "$start_mb" -ge "$end_mb" ]; then
                print_error "Not enough space to create partition $((i+1)): needed ${size_mb}MB, available $((end_mb - start_mb))MB"
                cleanup
                exit 1
            fi
            end="${end_mb}MiB"
            numeric_end_mb=$end_mb
        else
            end_val=$((start_mb + size_mb))
            # ensure we don't exceed usable area (should be caught by earlier checks)
            if [ "$end_val" -gt "$usable_mb" ]; then
                print_error "Partition $((i+1)) would exceed usable disk area (end ${end_val}MB > usable ${usable_mb}MB)"
                cleanup
                exit 1
            fi
            end="${end_val}MiB"
            numeric_end_mb=$end_val
        fi

        print_info "Creating partition $part_num: ${start_mb}MiB -> $end"

        case $fs in
            swap)
                try_mkpart "$LOOP_DEVICE" "$start_mb" "$numeric_end_mb" linux-swap
                ;;
            fat12|fat16|vfat)
                try_mkpart "$LOOP_DEVICE" "$start_mb" "$numeric_end_mb" fat32
                ;;
            ntfs)
                try_mkpart "$LOOP_DEVICE" "$start_mb" "$numeric_end_mb" ntfs
                ;;
            ext2|ext3|ext4)
                try_mkpart "$LOOP_DEVICE" "$start_mb" "$numeric_end_mb" ext4
                ;;
            xfs)
                try_mkpart "$LOOP_DEVICE" "$start_mb" "$numeric_end_mb" xfs
                ;;
            hfsplus)
                try_mkpart "$LOOP_DEVICE" "$start_mb" "$numeric_end_mb" hfs+
                ;;
            *)
                try_mkpart "$LOOP_DEVICE" "$start_mb" "$numeric_end_mb" ""
                ;;
        esac

        # advance start pointer for next partition (skip this for the explicitly-ended last mkpart)
        if [ "$i" -ne "$last_mkpart_idx" ]; then
            start_mb=$((start_mb + size_mb))
        else
            start_mb=$((end_mb))
        fi

        part_num=$((part_num + 1))
    done

    # Inform kernel about partition table changes and give it a moment to create /dev nodes
    partprobe "$LOOP_DEVICE" 2>/dev/null || true
    sleep 2

    print_success "Partitions created"
}

# Format the partitions
format_partitions() {
    local config_num=1
    local actual_part_num=1

    for config in "${PARTITION_CONFIGS[@]}"; do
        IFS='|' read -r fs size label <<< "$config"

        if [ "$fs" = "unallocated" ]; then
            print_info "Skipping unallocated space in config $config_num"
            config_num=$((config_num + 1))
            continue
        fi

        # Determine partition device name
        PARTITION="${LOOP_DEVICE}p${actual_part_num}"
        if [ ! -e "$PARTITION" ]; then
            PARTITION="${LOOP_DEVICE}${actual_part_num}"
        fi

        if [ ! -e "$PARTITION" ]; then
            print_error "Cannot find partition device for config $config_num (expected ${LOOP_DEVICE}p${actual_part_num} or ${LOOP_DEVICE}${actual_part_num})"
            cleanup
            exit 1
        fi

        print_info "Formatting config #${config_num} -> partition ${actual_part_num} ($PARTITION) with $fs filesystem..."

        case $fs in
            fat12)
                output=$(mkfs.fat -F 12 -n "$label" "$PARTITION" 2>&1)
                ret=$?
                if [ $ret -ne 0 ]; then
                    print_error "Failed to format partition ${actual_part_num} as FAT12"
                    echo "$output"
                    cleanup
                    exit 1
                fi
                echo "$output" | sed -n '1,50p'
                ;;
            fat16)
                output=$(mkfs.fat -F 16 -n "$label" "$PARTITION" 2>&1)
                ret=$?
                if [ $ret -ne 0 ]; then
                    print_error "Failed to format partition ${actual_part_num} as FAT16"
                    echo "$output"
                    cleanup
                    exit 1
                fi
                echo "$output" | sed -n '1,50p'
                ;;
            vfat)
                output=$(mkfs.vfat -F 32 -n "$label" "$PARTITION" 2>&1)
                ret=$?
                if [ $ret -ne 0 ]; then
                    print_error "Failed to format partition ${actual_part_num} as FAT32"
                    echo "$output"
                    cleanup
                    exit 1
                fi
                echo "$output" | sed -n '1,50p'
                ;;
            ntfs)
                output=$(mkfs.ntfs -f -L "$label" "$PARTITION" 2>&1)
                ret=$?
                if [ $ret -ne 0 ]; then
                    print_error "Failed to format partition ${actual_part_num} as NTFS"
                    echo "$output"
                    cleanup
                    exit 1
                fi
                echo "$output" | grep -E "^(Cluster|Creating|mkntfs completed)" || true
                ;;
            exfat)
                output=$(mkfs.exfat -n "$label" "$PARTITION" 2>&1)
                ret=$?
                if [ $ret -ne 0 ]; then
                    print_error "Failed to format partition ${actual_part_num} as exFAT"
                    echo "$output"
                    cleanup
                    exit 1
                fi
                echo "$output" | sed -n '1,50p'
                ;;
            ext2|ext3|ext4)
                output=$(mkfs."$fs" -L "$label" "$PARTITION" 2>&1)
                ret=$?
                if [ $ret -ne 0 ]; then
                    print_error "Failed to format partition ${actual_part_num} as $fs"
                    echo "$output"
                    cleanup
                    exit 1
                fi
                echo "$output" | grep -E "^(Creating|Writing|mke2fs)" || true
                ;;
            xfs)
                output=$(mkfs.xfs -f -L "$label" "$PARTITION" 2>&1)
                ret=$?
                if [ $ret -ne 0 ]; then
                    print_error "Failed to format partition ${actual_part_num} as XFS"
                    echo "$output"
                    cleanup
                    exit 1
                fi
                echo "$output" | sed -n '1,50p'
                ;;
            hfsplus)
                output=$(mkfs.hfsplus -v "$label" "$PARTITION" 2>&1)
                ret=$?
                if [ $ret -ne 0 ]; then
                    print_error "Failed to format partition ${actual_part_num} as HFS+"
                    echo "$output"
                    cleanup
                    exit 1
                fi
                echo "$output" | sed -n '1,50p'
                ;;
            apfs)
                print_warning "APFS formatting on Linux is not well supported"
                print_info "Skipping format for APFS partition"
                ;;
            swap)
                output=$(mkswap -L "SWAP${actual_part_num}" "$PARTITION" 2>&1)
                ret=$?
                if [ $ret -ne 0 ]; then
                    print_error "Failed to set up swap on partition ${actual_part_num}"
                    echo "$output"
                    cleanup
                    exit 1
                fi
                echo "$output" | grep -E "^Setting up" || true
                ;;
            *)
                print_warning "Unknown filesystem type: $fs - skipping format"
                ;;
        esac

        print_success "Partition ${actual_part_num} formatted (config ${config_num})"
        actual_part_num=$((actual_part_num + 1))
        config_num=$((config_num + 1))
    done
}

# Cleanup function
cleanup() {
    # Unmount any mounted filesystems
    if [ "${#MOUNT_POINTS[@]}" -gt 0 ]; then
        print_info "Unmounting filesystems..."
        for mp in "${MOUNT_POINTS[@]}"; do
            if mountpoint -q "$mp" 2>/dev/null; then
                umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
                print_info "Unmounted $mp"
            fi
            rmdir "$mp" 2>/dev/null || true
        done
    fi

    # Detach loop device
    if [ -n "$LOOP_DEVICE" ]; then
        print_info "Cleaning up loop device..."
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
}

# Mount filesystems
mount_filesystems() {
    echo ""
    read -p "Do you want to mount the filesystem(s) now? (y/n): " MOUNT_NOW
    
    if [ "$MOUNT_NOW" = "y" ]; then
        local part_num=1
        MOUNT_POINTS=()
        
        for config in "${PARTITION_CONFIGS[@]}"; do
            IFS='|' read -r fs size label <<< "$config"
            
            # Skip swap, apfs, and unallocated filesystems
            if [ "$fs" = "swap" ] || [ "$fs" = "apfs" ] || [ "$fs" = "unallocated" ]; then
                print_info "Skipping mount for $fs partition $part_num"
                part_num=$((part_num + 1))
                continue
            fi
            
            PARTITION="${LOOP_DEVICE}p${part_num}"
            if [ ! -e "$PARTITION" ]; then
                PARTITION="${LOOP_DEVICE}${part_num}"
            fi
            
            MOUNT_POINT="/mnt/forensic_p${part_num}_$$"
            mkdir -p "$MOUNT_POINT"
            
            print_info "Mounting partition $part_num to $MOUNT_POINT..."
            
            # Use appropriate mount options
            case $fs in
                ntfs)
                    mount -t ntfs-3g "$PARTITION" "$MOUNT_POINT" 2>&1 || \
                    mount "$PARTITION" "$MOUNT_POINT" 2>&1
                    ;;
                hfsplus)
                    mount -t hfsplus "$PARTITION" "$MOUNT_POINT" 2>&1
                    ;;
                *)
                    mount "$PARTITION" "$MOUNT_POINT" 2>&1
                    ;;
            esac
            
            if [ $? -eq 0 ]; then
                print_success "Partition $part_num mounted at: $MOUNT_POINT"
                MOUNT_POINTS+=("$MOUNT_POINT")
            else
                print_warning "Failed to mount partition $part_num"
                rmdir "$MOUNT_POINT" 2>/dev/null
            fi
            
            part_num=$((part_num + 1))
        done
    fi
}

# Display summary
show_summary() {
    echo ""
    echo "=========================================="
    echo "  Disk Image Creation Complete!"
    echo "=========================================="
    echo ""
    echo "Image File:        $(realpath $FILENAME)"
    echo "Size:              ${DISK_SIZE_MB} MB ($(echo "scale=2; $DISK_SIZE_MB/1024" | bc) GB)"
    echo "Init Method:       $INIT_METHOD"
    echo "Partition Scheme:  $PARTITION_SCHEME"
    echo "Loop Device:       $LOOP_DEVICE"
    echo ""
    echo "Partitions:"
    
    local part_num=1
    local config_num=1
    for config in "${PARTITION_CONFIGS[@]}"; do
        IFS='|' read -r fs size label <<< "$config"
        
        if [ "$fs" = "unallocated" ]; then
            echo "  [$config_num] unallocated space (${size}MB) - not partitioned"
        else
            PARTITION="${LOOP_DEVICE}p${part_num}"
            if [ ! -e "$PARTITION" ]; then
                PARTITION="${LOOP_DEVICE}${part_num}"
            fi
            
            if [ "$fs" = "swap" ]; then
                echo "  [$config_num] $PARTITION - $fs (${size}MB)"
            else
                echo "  [$config_num] $PARTITION - $fs (${size}MB) - '$label'"
            fi
            part_num=$((part_num + 1))
        fi
        
        config_num=$((config_num + 1))
    done
    
    if [ "${#MOUNT_POINTS[@]}" -gt 0 ]; then
        echo ""
        echo "Mount Points:"
        for mp in "${MOUNT_POINTS[@]}"; do
            echo "  $mp"
        done
    fi
    
    echo ""
    echo "=========================================="
    echo "  Forensic Analysis Commands"
    echo "=========================================="
    echo ""
    echo "View partition table:"
    echo "  sudo parted $FILENAME print"
    echo "  sudo fdisk -l $FILENAME"
    echo ""
    echo "Hex editor analysis:"
    echo "  hexdump -C $FILENAME | less"
    echo "  xxd $FILENAME | less"
    echo ""
    echo "Analyze with forensic tools:"
    echo "  mmls $FILENAME                    # View partitions"
    echo "  fsstat -o 2048 $FILENAME          # Filesystem details"
    echo "  fls -o 2048 -r $FILENAME          # List files"
    echo ""
    echo "View specific structures:"
    echo "  xxd -l 512 $FILENAME              # Boot sector"
    echo "  xxd -s 0x1BE -l 64 $FILENAME      # MBR partition table"
    echo ""
    echo "Clean up (when done):"
    if [ "${#MOUNT_POINTS[@]}" -gt 0 ]; then
        for mp in "${MOUNT_POINTS[@]}"; do
            echo "  sudo umount $mp"
        done
    fi
    echo "  sudo losetup -d $LOOP_DEVICE"
    echo ""
    
    print_tip "Remember to unmount filesystems and detach loop device when finished!"
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Main execution
main() {
    show_banner
    check_root
    check_dependencies
    check_filesystem_tools
    
    get_filename
    get_disk_size
    get_init_method
    get_preset_or_custom
    
    if [ "$USE_PRESET" = true ]; then
        apply_preset
        
        if [ "$ALLOW_PRESET_CUSTOMIZATION" = true ]; then
            # Show current config and allow modifications
            echo ""
            echo "Current preset configuration:"
            for i in $(seq 1 ${#PARTITION_CONFIGS[@]}); do
                config="${PARTITION_CONFIGS[$((i-1))]}"
                IFS='|' read -r fs size label <<< "$config"
                if [ "$fs" = "swap" ]; then
                    echo "  [$i] $fs (${size}MB)"
                else
                    echo "  [$i] $fs (${size}MB) - '$label'"
                fi
            done
            echo ""
            read -p "Modify partition configurations? (y/n): " modify
            if [ "$modify" = "y" ]; then
                get_partition_configs
            fi
        fi
    else
        # Custom layout
        get_partition_scheme
        get_partition_count
        get_partition_configs
    fi
    
    # Show final summary and confirm
    echo ""
    echo "=========================================="
    echo "  Configuration Summary"
    echo "=========================================="
    echo "Filename:          $FILENAME"
    echo "Size:              ${DISK_SIZE_MB} MB ($(echo "scale=2; $DISK_SIZE_MB/1024" | bc) GB)"
    echo "Init Method:       $INIT_METHOD"
    echo "Partition Scheme:  $PARTITION_SCHEME"
    echo "Partitions:        ${#PARTITION_CONFIGS[@]}"
    
    for i in $(seq 1 ${#PARTITION_CONFIGS[@]}); do
        config="${PARTITION_CONFIGS[$((i-1))]}"
        IFS='|' read -r fs size label <<< "$config"
        if [ "$fs" = "swap" ]; then
            echo "  [$i] $fs (${size}MB)"
        elif [ "$fs" = "unallocated" ]; then
            echo "  [$i] $fs (${size}MB) - no partition"
        else
            echo "  [$i] $fs (${size}MB) - '$label'"
        fi
    done
    
    echo ""
    read -p "Proceed with creation? (y/n): " CONFIRM
    
    if [ "$CONFIRM" != "y" ]; then
        print_info "Operation cancelled"
        exit 0
    fi
    
    echo ""
    create_disk_image
    setup_loop_device
    create_partitions
    format_partitions
    mount_filesystems
    
    show_summary
}

# Run main function
main