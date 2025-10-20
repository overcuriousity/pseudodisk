#!/bin/bash

# Forensic Disk Image Cleanup Helper
# Safely unmounts and detaches loop devices

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

echo ""
echo "=========================================="
echo "  Forensic Disk Cleanup Tool"
echo "=========================================="
echo ""

# Show current loop devices
print_info "Current loop devices:"
losetup -l

echo ""
read -p "Enter the disk image filename to clean up (or 'all' for all loop devices): " TARGET

if [ "$TARGET" = "all" ]; then
    print_warning "This will unmount and detach ALL loop devices!"
    read -p "Are you sure? (yes/no): " CONFIRM
    
    if [ "$CONFIRM" = "yes" ]; then
        # Get all loop devices
        LOOP_DEVICES=$(losetup -l -n -O NAME | tail -n +2)
        
        for LOOP in $LOOP_DEVICES; do
            print_info "Processing $LOOP..."
            
            # Try to unmount all partitions
            for PART in ${LOOP}p* ${LOOP}[0-9]*; do
                if [ -e "$PART" ]; then
                    MOUNT_POINT=$(findmnt -n -o TARGET "$PART" 2>/dev/null || true)
                    if [ -n "$MOUNT_POINT" ]; then
                        print_info "Unmounting $PART from $MOUNT_POINT"
                        umount "$PART" || print_warning "Failed to unmount $PART"
                    fi
                fi
            done
            
            # Detach loop device
            print_info "Detaching $LOOP"
            losetup -d "$LOOP" || print_warning "Failed to detach $LOOP"
        done
        
        print_success "Cleanup complete"
    else
        print_info "Cancelled"
    fi
else
    if [ ! -f "$TARGET" ]; then
        print_error "File not found: $TARGET"
        exit 1
    fi
    
    # Find loop device associated with this file
    LOOP_DEVICE=$(losetup -l -n -O NAME,BACK-FILE | grep "$(realpath $TARGET)" | awk '{print $1}')
    
    if [ -z "$LOOP_DEVICE" ]; then
        print_warning "No loop device found for $TARGET"
        exit 0
    fi
    
    print_info "Found loop device: $LOOP_DEVICE"
    
    # Try to unmount all partitions
    for PART in ${LOOP_DEVICE}p* ${LOOP_DEVICE}[0-9]*; do
        if [ -e "$PART" ]; then
            MOUNT_POINT=$(findmnt -n -o TARGET "$PART" 2>/dev/null || true)
            if [ -n "$MOUNT_POINT" ]; then
                print_info "Unmounting $PART from $MOUNT_POINT"
                umount "$PART" || print_warning "Failed to unmount $PART"
            fi
        fi
    done
    
    # Detach loop device
    print_info "Detaching $LOOP_DEVICE"
    losetup -d "$LOOP_DEVICE"
    
    print_success "Cleanup complete for $TARGET"
fi

echo ""
print_info "Current loop devices after cleanup:"
losetup -l
echo ""