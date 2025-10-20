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

# Function to get user loop devices (excluding system paths)
get_user_loop_devices() {
    losetup -l -n -O NAME,BACK-FILE | grep -v "/var/lib/snapd" | grep -v "/snap/" | grep -v "^$" | awk '{if (NF >= 2) print $0}'
}

# Function to display user loop devices nicely
show_user_loop_devices() {
    local devices=$(get_user_loop_devices)
    
    if [ -z "$devices" ]; then
        echo "No user loop devices found (system devices filtered out)"
        return 1
    fi
    
    echo "Active disk images:"
    echo ""
    printf "%-15s %s\n" "LOOP DEVICE" "IMAGE FILE"
    echo "------------------------------------------------------------"
    
    while IFS= read -r line; do
        local device=$(echo "$line" | awk '{print $1}')
        local file=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
        printf "%-15s %s\n" "$device" "$file"
    done <<< "$devices"
    
    echo ""
    return 0
}

# Function to unmount all partitions of a loop device
unmount_loop_partitions() {
    local loop_device=$1
    local unmounted=0
    
    # Try both naming conventions
    for part in ${loop_device}p* ${loop_device}[0-9]*; do
        if [ -e "$part" ]; then
            local mount_point=$(findmnt -n -o TARGET "$part" 2>/dev/null || true)
            if [ -n "$mount_point" ]; then
                print_info "Unmounting $part from $mount_point"
                if umount "$part"; then
                    print_success "Unmounted $part"
                    unmounted=$((unmounted + 1))
                else
                    print_warning "Failed to unmount $part"
                fi
            fi
        fi
    done
    
    return $unmounted
}

# Function to detach loop device
detach_loop_device() {
    local loop_device=$1
    
    print_info "Detaching $loop_device"
    
    # Check if device still exists in losetup output
    if ! losetup -l | grep -q "^$loop_device "; then
        print_success "Loop device already detached"
        return 0
    fi
    
    if losetup -d "$loop_device"; then
        print_success "Detached $loop_device"
        return 0
    else
        print_error "Failed to detach $loop_device"
        return 1
    fi
}

# Automatic mode
auto_cleanup() {
    local devices=$(get_user_loop_devices)
    
    if [ -z "$devices" ]; then
        print_info "No user loop devices to clean up"
        return 0
    fi
    
    echo "The following loop devices will be cleaned up:"
    echo ""
    
    local count=0
    while IFS= read -r line; do
        local device=$(echo "$line" | awk '{print $1}')
        local file=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
        echo "  [$((count+1))] $device -> $file"
        count=$((count+1))
    done <<< "$devices"
    
    echo ""
    read -p "Clean up all $count device(s)? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "Cancelled"
        return 0
    fi
    
    echo ""
    local success=0
    local failed=0
    
    while IFS= read -r line; do
        local device=$(echo "$line" | awk '{print $1}')
        local file=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
        
        echo "Processing: $device"
        unmount_loop_partitions "$device"
        
        if detach_loop_device "$device"; then
            success=$((success+1))
        else
            failed=$((failed+1))
        fi
        echo ""
    done <<< "$devices"
    
    echo "=========================================="
    print_success "Cleaned up: $success device(s)"
    if [ $failed -gt 0 ]; then
        print_warning "Failed: $failed device(s)"
    fi
    echo "=========================================="
}

# Manual mode - specific file
manual_cleanup() {
    local target=$1
    
    if [ ! -f "$target" ]; then
        print_error "File not found: $target"
        return 1
    fi
    
    # Find loop device associated with this file
    local loop_device=$(losetup -l -n -O NAME,BACK-FILE | grep "$(realpath $target)" | awk '{print $1}')
    
    if [ -z "$loop_device" ]; then
        print_warning "No loop device found for: $target"
        print_info "The file may already be detached"
        return 0
    fi
    
    print_info "Found loop device: $loop_device"
    echo ""
    
    unmount_loop_partitions "$loop_device"
    detach_loop_device "$loop_device"
    
    echo ""
    print_success "Cleanup complete for: $target"
}

# Interactive mode
interactive_cleanup() {
    local devices=$(get_user_loop_devices)
    
    if [ -z "$devices" ]; then
        print_info "No user loop devices to clean up"
        return 0
    fi
    
    echo "Select a device to clean up:"
    echo ""
    
    local -a device_array
    local -a file_array
    local count=0
    
    while IFS= read -r line; do
        local device=$(echo "$line" | awk '{print $1}')
        local file=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
        device_array[$count]=$device
        file_array[$count]=$file
        echo "  [$((count+1))] $device -> $file"
        count=$((count+1))
    done <<< "$devices"
    
    echo "  [a] Clean up ALL"
    echo "  [q] Quit"
    echo ""
    
    read -p "Enter selection: " selection
    
    if [ "$selection" = "q" ]; then
        print_info "Cancelled"
        return 0
    fi
    
    if [ "$selection" = "a" ]; then
        echo ""
        auto_cleanup
        return 0
    fi
    
    # Validate numeric input
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt $count ]; then
        print_error "Invalid selection"
        return 1
    fi
    
    local idx=$((selection-1))
    local device="${device_array[$idx]}"
    local file="${file_array[$idx]}"
    
    echo ""
    print_info "Cleaning up: $device -> $file"
    echo ""
    
    unmount_loop_partitions "$device"
    detach_loop_device "$device"
    
    echo ""
    print_success "Cleanup complete"
}

# Main menu
main() {
    # Check if any user loop devices exist
    if ! show_user_loop_devices; then
        exit 0
    fi
    
    echo "Cleanup Options:"
    echo "  1) Select specific device (interactive)"
    echo "  2) Clean up all user devices (automatic)"
    echo "  3) Enter filename manually"
    echo "  4) Quit"
    echo ""
    read -p "Select option [1-4]: " option
    
    echo ""
    
    case $option in
        1)
            interactive_cleanup
            ;;
        2)
            auto_cleanup
            ;;
        3)
            read -p "Enter disk image filename: " filename
            echo ""
            manual_cleanup "$filename"
            ;;
        4)
            print_info "Cancelled"
            ;;
        *)
            print_error "Invalid option"
            exit 1
            ;;
    esac
    
    echo ""
    
    # Show final state
    if get_user_loop_devices >/dev/null 2>&1; then
        echo "Remaining loop devices:"
        show_user_loop_devices
    else
        print_success "All user loop devices cleaned up"
    fi
}

# Run main
main