#!/bin/bash

# Forensic Practice Disk Image Creator
# Creates disk images with various filesystems for forensic analysis practice

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    
    # NTFS
    if command -v mkfs.ntfs >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} NTFS    (mkfs.ntfs available)"
    else
        echo -e "  ${YELLOW}✗${NC} NTFS    (install: sudo apt-get install ntfs-3g)"
    fi
    
    # FAT32
    if command -v mkfs.vfat >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} FAT32   (mkfs.vfat available)"
    else
        echo -e "  ${YELLOW}✗${NC} FAT32   (install: sudo apt-get install dosfstools)"
    fi
    
    # exFAT
    if command -v mkfs.exfat >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} exFAT   (mkfs.exfat available)"
    else
        echo -e "  ${YELLOW}✗${NC} exFAT   (install: sudo apt-get install exfat-fuse exfat-utils)"
    fi
    
    # ext2/3/4
    if command -v mkfs.ext4 >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} ext2/3/4 (mkfs.ext4 available)"
    else
        echo -e "  ${YELLOW}✗${NC} ext2/3/4 (install: sudo apt-get install e2fsprogs)"
    fi
    
    # XFS
    if command -v mkfs.xfs >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} XFS     (mkfs.xfs available)"
    else
        echo -e "  ${YELLOW}✗${NC} XFS     (install: sudo apt-get install xfsprogs)"
    fi
    
    # swap
    if command -v mkswap >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} swap    (mkswap available)"
    else
        echo -e "  ${YELLOW}✗${NC} swap    (should be in util-linux)"
    fi
    
    echo ""
}

# Display banner
show_banner() {
    echo ""
    echo "=========================================="
    echo "  Forensic Disk Image Creator"
    echo "=========================================="
    echo ""
}

# Get filename from user
get_filename() {
    echo ""
    read -p "Enter output filename (default: forensic_disk.dd): " FILENAME
    FILENAME=${FILENAME:-forensic_disk.dd}
    
    if [ -f "$FILENAME" ]; then
        read -p "File already exists. Overwrite? (y/n): " OVERWRITE
        if [ "$OVERWRITE" != "y" ]; then
            print_info "Exiting..."
            exit 0
        fi
    fi
}

# Get disk size from user
get_disk_size() {
    echo ""
    echo "Disk Size Options:"
    echo "  1) 100 MB  (small, quick testing)"
    echo "  2) 500 MB  (medium)"
    echo "  3) 1 GB    (standard)"
    echo "  4) 5 GB    (large)"
    echo "  5) Custom size"
    echo ""
    read -p "Select disk size [1-5]: " SIZE_CHOICE
    
    case $SIZE_CHOICE in
        1) DISK_SIZE_MB=100 ;;
        2) DISK_SIZE_MB=500 ;;
        3) DISK_SIZE_MB=1024 ;;
        4) DISK_SIZE_MB=5120 ;;
        5)
            read -p "Enter size in MB: " DISK_SIZE_MB
            if ! [[ "$DISK_SIZE_MB" =~ ^[0-9]+$ ]] || [ "$DISK_SIZE_MB" -lt 10 ]; then
                print_error "Invalid size. Must be at least 10 MB"
                exit 1
            fi
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
    
    print_info "Selected disk size: ${DISK_SIZE_MB} MB"
}

# Get initialization method
get_init_method() {
    echo ""
    echo "Initialization Method:"
    echo "  1) /dev/zero   (Fast, zeros - forensically predictable)"
    echo "  2) /dev/random (Slow, random data - more realistic)"
    echo "  3) fallocate   (Fastest, sparse file)"
    echo ""
    read -p "Select initialization method [1-3]: " INIT_CHOICE
    
    case $INIT_CHOICE in
        1) INIT_METHOD="zero" ;;
        2) INIT_METHOD="random" ;;
        3) INIT_METHOD="fallocate" ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
    
    print_info "Selected initialization method: $INIT_METHOD"
}

# Get partition scheme
get_partition_scheme() {
    echo ""
    echo "Partition Scheme:"
    echo "  1) GPT (GUID Partition Table) - Modern, Windows 10/11 default"
    echo "  2) MBR (Master Boot Record) - Legacy, compatible with older systems"
    echo ""
    read -p "Select partition scheme [1-2]: " PARTITION_CHOICE
    
    case $PARTITION_CHOICE in
        1) PARTITION_SCHEME="gpt" ;;
        2) PARTITION_SCHEME="msdos" ;;
        *)
            print_error "Invalid choice"
            exit 1
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
        exit 1
    fi
    
    print_info "Creating $PARTITION_COUNT partition(s)"
}

# Get partition configurations
get_partition_configs() {
    PARTITION_CONFIGS=()
    
    for i in $(seq 1 $PARTITION_COUNT); do
        echo ""
        echo "=========================================="
        echo "  Partition $i Configuration"
        echo "=========================================="
        
        # Get filesystem
        echo ""
        echo "Filesystem Type:"
        echo "  1) NTFS    (Windows default)"
        echo "  2) FAT32   (Universal compatibility)"
        echo "  3) exFAT   (Modern, large file support)"
        echo "  4) ext4    (Linux default)"
        echo "  5) ext3    (Older Linux)"
        echo "  6) ext2    (Legacy Linux, no journaling)"
        echo "  7) XFS     (High-performance Linux)"
        echo "  8) swap    (Linux swap space)"
        echo ""
        read -p "Select filesystem for partition $i [1-8]: " FS_CHOICE
        
        case $FS_CHOICE in
            1) 
                PART_FS="ntfs"
                if ! command -v mkfs.ntfs >/dev/null 2>&1; then
                    print_error "mkfs.ntfs not found. Install: sudo apt-get install ntfs-3g"
                    exit 1
                fi
                ;;
            2) 
                PART_FS="vfat"
                if ! command -v mkfs.vfat >/dev/null 2>&1; then
                    print_error "mkfs.vfat not found. Install: sudo apt-get install dosfstools"
                    exit 1
                fi
                ;;
            3) 
                PART_FS="exfat"
                if ! command -v mkfs.exfat >/dev/null 2>&1; then
                    print_error "mkfs.exfat not found. Install: sudo apt-get install exfat-fuse exfat-utils"
                    exit 1
                fi
                ;;
            4) 
                PART_FS="ext4"
                if ! command -v mkfs.ext4 >/dev/null 2>&1; then
                    print_error "mkfs.ext4 not found. Install: sudo apt-get install e2fsprogs"
                    exit 1
                fi
                ;;
            5) 
                PART_FS="ext3"
                if ! command -v mkfs.ext3 >/dev/null 2>&1; then
                    print_error "mkfs.ext3 not found. Install: sudo apt-get install e2fsprogs"
                    exit 1
                fi
                ;;
            6) 
                PART_FS="ext2"
                if ! command -v mkfs.ext2 >/dev/null 2>&1; then
                    print_error "mkfs.ext2 not found. Install: sudo apt-get install e2fsprogs"
                    exit 1
                fi
                ;;
            7) 
                PART_FS="xfs"
                if ! command -v mkfs.xfs >/dev/null 2>&1; then
                    print_error "mkfs.xfs not found. Install: sudo apt-get install xfsprogs"
                    exit 1
                fi
                ;;
            8)
                PART_FS="swap"
                if ! command -v mkswap >/dev/null 2>&1; then
                    print_error "mkswap not found. Install: sudo apt-get install util-linux"
                    exit 1
                fi
                ;;
            *)
                print_error "Invalid choice"
                exit 1
                ;;
        esac
        
        # Get size
        if [ $i -lt $PARTITION_COUNT ]; then
            read -p "Size for partition $i in MB: " PART_SIZE
            if ! [[ "$PART_SIZE" =~ ^[0-9]+$ ]] || [ "$PART_SIZE" -lt 1 ]; then
                print_error "Invalid size"
                exit 1
            fi
        else
            PART_SIZE="remaining"
            print_info "Partition $i will use remaining space"
        fi
        
        # Get label (skip for swap)
        if [ "$PART_FS" != "swap" ]; then
            read -p "Volume label for partition $i (default: PART$i): " PART_LABEL
            PART_LABEL=${PART_LABEL:-PART$i}
        else
            PART_LABEL=""
        fi
        
        PARTITION_CONFIGS+=("$PART_FS|$PART_SIZE|$PART_LABEL")
        print_info "Partition $i: $PART_FS, ${PART_SIZE}MB, label='$PART_LABEL'"
    done
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
                dd if=/dev/zero of="$FILENAME" bs=1M count=$DISK_SIZE_MB status=progress
            fi
            ;;
        zero)
            dd if=/dev/zero of="$FILENAME" bs=1M count=$DISK_SIZE_MB status=progress
            ;;
        random)
            print_warning "Using /dev/urandom - this will be SLOW!"
            dd if=/dev/urandom of="$FILENAME" bs=1M count=$DISK_SIZE_MB status=progress
            ;;
    esac
    
    print_success "Disk image created with $INIT_METHOD"
}

# Setup loop device
setup_loop_device() {
    print_info "Setting up loop device..."
    LOOP_DEVICE=$(losetup -f)
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
            end="${start_mb}MiB + ${size}MiB"
            end=$(echo "$start_mb + $size" | bc)
            end="${end}MiB"
        fi
        
        print_info "Creating partition $part_num: ${start_mb}MiB -> $end"
        
        if [ "$fs" = "swap" ]; then
            parted -s "$LOOP_DEVICE" mkpart primary linux-swap "${start_mb}MiB" "$end"
        else
            parted -s "$LOOP_DEVICE" mkpart primary "${start_mb}MiB" "$end"
        fi
        
        if [ "$size" != "remaining" ]; then
            start_mb=$(echo "$start_mb + $size" | bc)
        fi
        
        part_num=$((part_num + 1))
    done
    
    # Inform kernel about partition table changes
    partprobe "$LOOP_DEVICE"
    sleep 2
    
    print_success "Partitions created"
}

# Format the partitions
format_partitions() {
    local part_num=1
    
    for config in "${PARTITION_CONFIGS[@]}"; do
        IFS='|' read -r fs size label <<< "$config"
        
        # Determine partition device name
        PARTITION="${LOOP_DEVICE}p${part_num}"
        if [ ! -e "$PARTITION" ]; then
            PARTITION="${LOOP_DEVICE}${part_num}"
        fi
        
        if [ ! -e "$PARTITION" ]; then
            print_error "Cannot find partition device for partition $part_num"
            cleanup
            exit 1
        fi
        
        print_info "Formatting partition $part_num ($PARTITION) with $fs filesystem..."
        
        case $fs in
            ntfs)
                mkfs.ntfs -f -L "$label" "$PARTITION"
                ;;
            vfat)
                mkfs.vfat -n "$label" "$PARTITION"
                ;;
            exfat)
                mkfs.exfat -n "$label" "$PARTITION"
                ;;
            ext2|ext3|ext4)
                mkfs."$fs" -L "$label" "$PARTITION"
                ;;
            xfs)
                mkfs.xfs -f -L "$label" "$PARTITION"
                ;;
            swap)
                mkswap -L "SWAP$part_num" "$PARTITION"
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
            
            # Skip swap partitions
            if [ "$fs" = "swap" ]; then
                print_info "Skipping mount for swap partition $part_num"
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
            mount "$PARTITION" "$MOUNT_POINT"
            
            print_success "Partition $part_num mounted at: $MOUNT_POINT"
            MOUNT_POINTS+=("$MOUNT_POINT")
            
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
    echo "Size:              ${DISK_SIZE_MB} MB"
    echo "Init Method:       $INIT_METHOD"
    echo "Partition Scheme:  $PARTITION_SCHEME"
    echo "Loop Device:       $LOOP_DEVICE"
    echo ""
    echo "Partitions:"
    
    local part_num=1
    for config in "${PARTITION_CONFIGS[@]}"; do
        IFS='|' read -r fs size label <<< "$config"
        
        PARTITION="${LOOP_DEVICE}p${part_num}"
        if [ ! -e "$PARTITION" ]; then
            PARTITION="${LOOP_DEVICE}${part_num}"
        fi
        
        if [ "$fs" = "swap" ]; then
            echo "  [$part_num] $PARTITION - $fs (${size}MB)"
        else
            echo "  [$part_num] $PARTITION - $fs (${size}MB) - '$label'"
        fi
        
        part_num=$((part_num + 1))
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
    echo "  mmls $FILENAME"
    echo ""
    echo "Clean up (when done):"
    if [ ${#MOUNT_POINTS[@]} -gt 0 ]; then
        for mp in "${MOUNT_POINTS[@]}"; do
            echo "  sudo umount $mp"
        done
    fi
    echo "  sudo losetup -d $LOOP_DEVICE"
    echo ""
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
    get_partition_scheme
    get_partition_count
    get_partition_configs
    
    echo ""
    echo "=========================================="
    echo "  Summary"
    echo "=========================================="
    echo "Filename:          $FILENAME"
    echo "Size:              ${DISK_SIZE_MB} MB"
    echo "Init Method:       $INIT_METHOD"
    echo "Partition Scheme:  $PARTITION_SCHEME"
    echo "Partitions:        $PARTITION_COUNT"
    
    for i in $(seq 1 $PARTITION_COUNT); do
        config="${PARTITION_CONFIGS[$((i-1))]}"
        IFS='|' read -r fs size label <<< "$config"
        if [ "$fs" = "swap" ]; then
            echo "  [$i] $fs (${size}MB)"
        else
            echo "  [$i] $fs (${size}MB) - '$label'"
        fi
    done
    
    echo ""
    read -p "Proceed with creation? (y/n): " CONFIRM
    
    if [ "$CONFIRM" != "y" ]; then
        print_info "Cancelled"
        exit 0
    fi
    
    create_disk_image
    setup_loop_device
    create_partitions
    format_partitions
    mount_filesystems
    
    show_summary
}

# Run main function
main