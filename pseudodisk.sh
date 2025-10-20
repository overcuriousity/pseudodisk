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
    command -v mkfs.ext4 >/dev/null 2>&1 || missing_tools+=("e2fsprogs")
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required packages: ${missing_tools[*]}"
        print_info "Install with: sudo apt-get install ${missing_tools[*]}"
        exit 1
    fi
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

# Get filesystem type
get_filesystem() {
    echo ""
    echo "Filesystem Type:"
    echo "  1) NTFS    (Windows default, requires ntfs-3g)"
    echo "  2) FAT32   (Universal compatibility, 4GB file limit)"
    echo "  3) exFAT   (Modern, large file support)"
    echo "  4) ext4    (Linux default)"
    echo "  5) ext3    (Older Linux)"
    echo "  6) ext2    (Legacy Linux, no journaling)"
    echo "  7) XFS     (High-performance Linux)"
    echo ""
    read -p "Select filesystem [1-7]: " FS_CHOICE
    
    case $FS_CHOICE in
        1) 
            FILESYSTEM="ntfs"
            if ! command -v mkfs.ntfs >/dev/null 2>&1; then
                print_error "mkfs.ntfs not found. Install with: sudo apt-get install ntfs-3g"
                exit 1
            fi
            ;;
        2) FILESYSTEM="vfat" ;;
        3) 
            FILESYSTEM="exfat"
            if ! command -v mkfs.exfat >/dev/null 2>&1; then
                print_error "mkfs.exfat not found. Install with: sudo apt-get install exfat-utils"
                exit 1
            fi
            ;;
        4) FILESYSTEM="ext4" ;;
        5) FILESYSTEM="ext3" ;;
        6) FILESYSTEM="ext2" ;;
        7) 
            FILESYSTEM="xfs"
            if ! command -v mkfs.xfs >/dev/null 2>&1; then
                print_error "mkfs.xfs not found. Install with: sudo apt-get install xfsprogs"
                exit 1
            fi
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
    
    print_info "Selected filesystem: $FILESYSTEM"
}

# Get volume label
get_volume_label() {
    echo ""
    read -p "Enter volume label (default: FORENSIC): " VOLUME_LABEL
    VOLUME_LABEL=${VOLUME_LABEL:-FORENSIC}
}

# Create the disk image
create_disk_image() {
    print_info "Creating disk image file: $FILENAME (${DISK_SIZE_MB} MB)..."
    
    # Use fallocate for faster creation if available
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l ${DISK_SIZE_MB}M "$FILENAME"
    else
        dd if=/dev/zero of="$FILENAME" bs=1M count=$DISK_SIZE_MB status=progress
    fi
    
    print_success "Disk image created"
}

# Setup loop device
setup_loop_device() {
    print_info "Setting up loop device..."
    LOOP_DEVICE=$(losetup -f)
    losetup "$LOOP_DEVICE" "$FILENAME"
    print_success "Loop device created: $LOOP_DEVICE"
}

# Create partition table and partition
create_partitions() {
    print_info "Creating $PARTITION_SCHEME partition table..."
    
    parted -s "$LOOP_DEVICE" mklabel "$PARTITION_SCHEME"
    
    print_info "Creating partition..."
    
    if [ "$PARTITION_SCHEME" = "gpt" ]; then
        # For GPT, leave 1MB at start and end for alignment
        parted -s "$LOOP_DEVICE" mkpart primary 1MiB 100%
    else
        # For MBR
        parted -s "$LOOP_DEVICE" mkpart primary 1MiB 100%
    fi
    
    # Inform kernel about partition table changes
    partprobe "$LOOP_DEVICE"
    sleep 1
    
    print_success "Partition created"
}

# Format the partition
format_partition() {
    PARTITION="${LOOP_DEVICE}p1"
    
    # Check if partition device exists
    if [ ! -e "$PARTITION" ]; then
        print_warning "Partition device $PARTITION not found, trying alternative..."
        PARTITION="${LOOP_DEVICE}1"
    fi
    
    if [ ! -e "$PARTITION" ]; then
        print_error "Cannot find partition device"
        cleanup
        exit 1
    fi
    
    print_info "Formatting partition with $FILESYSTEM filesystem..."
    
    case $FILESYSTEM in
        ntfs)
            mkfs.ntfs -f -L "$VOLUME_LABEL" "$PARTITION"
            ;;
        vfat)
            mkfs.vfat -n "$VOLUME_LABEL" "$PARTITION"
            ;;
        exfat)
            mkfs.exfat -n "$VOLUME_LABEL" "$PARTITION"
            ;;
        ext2|ext3|ext4)
            mkfs."$FILESYSTEM" -L "$VOLUME_LABEL" "$PARTITION"
            ;;
        xfs)
            mkfs.xfs -f -L "$VOLUME_LABEL" "$PARTITION"
            ;;
    esac
    
    print_success "Filesystem created"
}

# Cleanup function
cleanup() {
    if [ -n "$LOOP_DEVICE" ]; then
        print_info "Cleaning up loop device..."
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
}

# Mount the filesystem
mount_filesystem() {
    echo ""
    read -p "Do you want to mount the filesystem now? (y/n): " MOUNT_NOW
    
    if [ "$MOUNT_NOW" = "y" ]; then
        MOUNT_POINT="/mnt/forensic_disk_$$"
        mkdir -p "$MOUNT_POINT"
        
        print_info "Mounting to $MOUNT_POINT..."
        mount "$PARTITION" "$MOUNT_POINT"
        
        print_success "Filesystem mounted at: $MOUNT_POINT"
        print_info "To unmount: sudo umount $MOUNT_POINT"
        
        MOUNTED=true
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
    echo "Partition Scheme:  $PARTITION_SCHEME"
    echo "Filesystem:        $FILESYSTEM"
    echo "Volume Label:      $VOLUME_LABEL"
    echo "Loop Device:       $LOOP_DEVICE"
    echo "Partition:         $PARTITION"
    if [ "$MOUNTED" = true ]; then
        echo "Mount Point:       $MOUNT_POINT"
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
    echo "  sudo apt-get install bless  # GUI hex editor"
    echo "  bless $FILENAME"
    echo ""
    echo "Mount the image later:"
    echo "  sudo losetup -f $FILENAME"
    echo "  sudo losetup -l  # List loop devices"
    echo "  sudo mount /dev/loopXp1 /mnt/mountpoint"
    echo ""
    echo "Analyze with forensic tools:"
    echo "  sudo apt-get install sleuthkit"
    echo "  mmls $FILENAME  # Show partition layout"
    echo "  fsstat -o 2048 $FILENAME  # Filesystem details"
    echo "  fls -o 2048 $FILENAME  # List files"
    echo ""
    echo "Clean up (when done):"
    if [ "$MOUNTED" = true ]; then
        echo "  sudo umount $MOUNT_POINT"
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
    
    get_filename
    get_disk_size
    get_partition_scheme
    get_filesystem
    get_volume_label
    
    echo ""
    echo "=========================================="
    echo "  Summary"
    echo "=========================================="
    echo "Filename:          $FILENAME"
    echo "Size:              ${DISK_SIZE_MB} MB"
    echo "Partition Scheme:  $PARTITION_SCHEME"
    echo "Filesystem:        $FILESYSTEM"
    echo "Volume Label:      $VOLUME_LABEL"
    echo ""
    read -p "Proceed with creation? (y/n): " CONFIRM
    
    if [ "$CONFIRM" != "y" ]; then
        print_info "Cancelled"
        exit 0
    fi
    
    create_disk_image
    setup_loop_device
    create_partitions
    format_partition
    mount_filesystem
    
    show_summary
}

# Run main function
main