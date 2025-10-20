#!/bin/bash

# Forensic Practice Disk Image Creator - Enhanced Version
# Creates disk images with various filesystems for forensic analysis practice
# Now with improved UX, sanity checks, and extended filesystem support

#set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

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
    
    # FAT12/16
    if command -v mkfs.fat >/dev/null 2>&1 || command -v mkfs.vfat >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} FAT12/16 (mkfs.fat available)"
    else
        echo -e "  ${YELLOW}✗${NC} FAT12/16 (install: sudo apt-get install dosfstools)"
    fi
    
    # FAT32
    if command -v mkfs.vfat >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} FAT32    (mkfs.vfat available)"
    else
        echo -e "  ${YELLOW}✗${NC} FAT32    (install: sudo apt-get install dosfstools)"
    fi
    
    # exFAT
    if command -v mkfs.exfat >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} exFAT    (mkfs.exfat available)"
    else
        echo -e "  ${YELLOW}✗${NC} exFAT    (install: sudo apt-get install exfatprogs)"
    fi
    
    # NTFS
    if command -v mkfs.ntfs >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} NTFS     (mkfs.ntfs available)"
    else
        echo -e "  ${YELLOW}✗${NC} NTFS     (install: sudo apt-get install ntfs-3g)"
    fi
    
    # ext2/3/4
    if command -v mkfs.ext4 >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} ext2/3/4 (mkfs.ext4 available)"
    else
        echo -e "  ${YELLOW}✗${NC} ext2/3/4 (install: sudo apt-get install e2fsprogs)"
    fi
    
    # XFS
    if command -v mkfs.xfs >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} XFS      (mkfs.xfs available)"
    else
        echo -e "  ${YELLOW}✗${NC} XFS      (install: sudo apt-get install xfsprogs)"
    fi
    
    # HFS+
    if command -v mkfs.hfsplus >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} HFS+     (mkfs.hfsplus available)"
    else
        echo -e "  ${YELLOW}✗${NC} HFS+     (install: sudo apt-get install hfsprogs)"
    fi
    
    # APFS
    if command -v mkfs.apfs >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} APFS     (mkfs.apfs available)"
    else
        echo -e "  ${YELLOW}✗${NC} APFS     (limited Linux support - not recommended)"
    fi
    
    # swap
    if command -v mkswap >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} swap     (mkswap available)"
    else
        echo -e "  ${YELLOW}✗${NC} swap     (should be in util-linux)"
    fi
    
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
    
    # Validate filename
    if [[ "$FILENAME" =~ [^a-zA-Z0-9._-] ]]; then
        print_warning "Filename contains special characters. This may cause issues."
        read -p "Continue with this filename? (y/n): " continue
        if [ "$continue" != "y" ]; then
            get_filename
            return
        fi
    fi
    
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
            read -p "Enter size in MB: " DISK_SIZE_MB
            if ! [[ "$DISK_SIZE_MB" =~ ^[0-9]+$ ]] || [ "$DISK_SIZE_MB" -lt 10 ]; then
                print_error "Invalid size. Must be at least 10 MB"
                get_disk_size
                return
            fi
            if [ "$DISK_SIZE_MB" -gt 102400 ]; then
                print_warning "Very large disk size (>100GB). This may take a while."
                read -p "Continue? (y/n): " continue
                if [ "$continue" != "y" ]; then
                    get_disk_size
                    return
                fi
            fi
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
            print_note "Single FAT12 partition (max 16MB)"
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
            if [ "$root_size" -lt 5120 ]; then
                root_size=5120  # Minimum 5GB for root
            fi
            if [ "$root_size" -gt $((DISK_SIZE_MB - 1024)) ]; then
                root_size=$((DISK_SIZE_MB / 2))  # If not enough space, use half
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
    local available_space=$((DISK_SIZE_MB - 2))  # Reserve 2MB for partition table
    
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
                fallocate -l ${DISK_SIZE_MB}M "$FILENAME"
            else
                print_warning "fallocate not available, falling back to /dev/zero"
                dd if=/dev/zero of="$FILENAME" bs=1M count=$DISK_SIZE_MB status=progress 2>&1 | grep -v "records"
            fi
            ;;
        zero)
            dd if=/dev/zero of="$FILENAME" bs=1M count=$DISK_SIZE_MB status=progress 2>&1 | grep -v "records"
            ;;
        random)
            print_warning "Using /dev/urandom - this will be SLOW!"
            dd if=/dev/urandom of="$FILENAME" bs=1M count=$DISK_SIZE_MB status=progress 2>&1 | grep -v "records"
            ;;
    esac
    
    print_success "Disk image created with $INIT_METHOD"
}

# Setup loop device
setup_loop_device() {
    print_info "Setting up loop device..."
    LOOP_DEVICE=$(losetup -f)
    
    if [ -z "$LOOP_DEVICE" ]; then
        print_error "No free loop devices available"
        print_info "Try: sudo modprobe loop max_loop=16"
        exit 1
    fi
    
    losetup "$LOOP_DEVICE" "$FILENAME"
    print_success "Loop device created: $LOOP_DEVICE"
}

# Create partition table and partitions
create_partitions() {
    print_info "Creating $PARTITION_SCHEME partition table..."
    
    parted -s "$LOOP_DEVICE" mklabel "$PARTITION_SCHEME"
    
    local start_mb=1
    local part_num=1
    
    for config in "${PARTITION_CONFIGS[@]}"; do
        IFS='|' read -r fs size label <<< "$config"
        
        if [ "$size" = "remaining" ]; then
            end="100%"
        else
            end=$(echo "$start_mb + $size" | bc)
            end="${end}MiB"
        fi
        
        print_info "Creating partition $part_num: ${start_mb}MiB -> $end"
        
        # Set partition type based on filesystem
        case $fs in
            swap)
                parted -s "$LOOP_DEVICE" mkpart primary linux-swap "${start_mb}MiB" "$end"
                ;;
            fat12|fat16|vfat)
                parted -s "$LOOP_DEVICE" mkpart primary fat32 "${start_mb}MiB" "$end"
                ;;
            ntfs)
                parted -s "$LOOP_DEVICE" mkpart primary ntfs "${start_mb}MiB" "$end"
                ;;
            ext2|ext3|ext4)
                parted -s "$LOOP_DEVICE" mkpart primary ext4 "${start_mb}MiB" "$end"
                ;;
            xfs)
                parted -s "$LOOP_DEVICE" mkpart primary xfs "${start_mb}MiB" "$end"
                ;;
            hfsplus)
                parted -s "$LOOP_DEVICE" mkpart primary hfs+ "${start_mb}MiB" "$end"
                ;;
            unallocated)
                # Don't create a partition for unallocated space - just leave it empty
                print_info "Leaving space unallocated (no partition entry)"
                ;;
            *)
                parted -s "$LOOP_DEVICE" mkpart primary "${start_mb}MiB" "$end"
                ;;
        esac
        
        if [ "$size" != "remaining" ]; then
            start_mb=$(echo "$start_mb + $size" | bc)
        fi
        
        part_num=$((part_num + 1))
    done
    
    # Inform kernel about partition table changes
    partprobe "$LOOP_DEVICE" 2>/dev/null || true
    sleep 2
    
    print_success "Partitions created"
}

# Format the partitions
format_partitions() {
    local part_num=1
    
    for config in "${PARTITION_CONFIGS[@]}"; do
        IFS='|' read -r fs size label <<< "$config"
        
        # Skip unallocated space - no partition to format
        if [ "$fs" = "unallocated" ]; then
            print_info "Skipping unallocated space (no partition to format)"
            continue
        fi
        
        # Determine partition device name
        PARTITION="${LOOP_DEVICE}p${part_num}"
        if [ ! -e "$PARTITION" ]; then
            PARTITION="${LOOP_DEVICE}${part_num}"
        fi
        
        if [ ! -e "$PARTITION" ]; then
            print_error "Cannot find partition device for partition $part_num"
            print_info "Expected: ${LOOP_DEVICE}p${part_num} or ${LOOP_DEVICE}${part_num}"
            cleanup
            exit 1
        fi
        
        print_info "Formatting partition $part_num ($PARTITION) with $fs filesystem..."
        
        case $fs in
            fat12)
                # FAT12 requires specific cluster size
                mkfs.fat -F 12 -n "$label" "$PARTITION" 2>&1 | grep -v "^mkfs.fat"
                ;;
            fat16)
                # FAT16
                mkfs.fat -F 16 -n "$label" "$PARTITION" 2>&1 | grep -v "^mkfs.fat"
                ;;
            vfat)
                # FAT32
                mkfs.vfat -F 32 -n "$label" "$PARTITION" 2>&1 | grep -v "^mkfs.fat"
                ;;
            ntfs)
                mkfs.ntfs -f -L "$label" "$PARTITION" 2>&1 | grep -E "^(Cluster|Creating|mkntfs completed)"
                ;;
            exfat)
                mkfs.exfat -n "$label" "$PARTITION" 2>&1 | grep -v "^exfatprogs"
                ;;
            ext2|ext3|ext4)
                mkfs."$fs" -L "$label" "$PARTITION" 2>&1 | grep -E "^(Creating|Writing|mke2fs)"
                ;;
            xfs)
                mkfs.xfs -f -L "$label" "$PARTITION" 2>&1 | grep -v "^meta-data"
                ;;
            hfsplus)
                mkfs.hfsplus -v "$label" "$PARTITION" 2>&1
                ;;
            apfs)
                print_warning "APFS formatting on Linux is not well supported"
                print_info "Skipping format for APFS partition"
                ;;
            swap)
                mkswap -L "SWAP$part_num" "$PARTITION" 2>&1 | grep "^Setting up"
                ;;
        esac
        
        print_success "Partition $part_num formatted"
        part_num=$((part_num + 1))
    done
}

# Cleanup function
cleanup() {
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
    
    if [ ${#MOUNT_POINTS[@]} -gt 0 ]; then
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
    if [ ${#MOUNT_POINTS[@]} -gt 0 ]; then
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