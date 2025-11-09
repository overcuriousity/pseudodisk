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

# Helper to list processes blocking a device (if possible)
list_blocking_processes() {
    local dev="$1"
    if command -v fuser >/dev/null 2>&1; then
        fuser -v "$dev" 2>/dev/null || true
    elif command -v lsof >/dev/null 2>&1; then
        lsof "$dev" 2>/dev/null || true
    else
        print_info "Install 'psmisc' (provides fuser) or 'lsof' to list blocking processes"
    fi
}

# Function to unmount all partitions of a loop device
unmount_loop_partitions() {
    local loop_device=$1
    local unmounted=0

    # Build a list of partition nodes for this loop device
    local parts=()
    for p in "${loop_device}p"* "${loop_device}"[0-9]*; do
        # Only consider block device nodes that actually exist
        if [ -b "$p" ]; then
            parts+=("$p")
        fi
    done

    if [ ${#parts[@]} -eq 0 ]; then
        print_info "No partition block devices found for $loop_device"
        return 0
    fi

    for part in "${parts[@]}"; do
        # Determine if the partition is mounted
        local mount_point
        mount_point=$(findmnt -n -o TARGET --source "$part" 2>/dev/null || true)
        if [ -n "$mount_point" ]; then
            print_info "Unmounting $part from $mount_point"
            if umount "$part" 2>/dev/null; then
                print_success "Unmounted $part"
                unmounted=$((unmounted + 1))
            else
                print_warning "Regular umount failed for $part - attempting lazy unmount"
                if umount -l "$part" 2>/dev/null; then
                    print_success "Lazy-unmounted $part"
                    unmounted=$((unmounted + 1))
                else
                    print_warning "Failed to unmount $part even with lazy unmount"
                fi
            fi
        else
            print_info "Partition $part does not appear to be mounted"
        fi
    done

    # Attempt to remove partition mappings so kernel releases device nodes
    if command -v partx >/dev/null 2>&1; then
        partx -d "$loop_device" 2>/dev/null || true
    elif command -v kpartx >/dev/null 2>&1; then
        kpartx -d "$loop_device" 2>/dev/null || true
    fi

    # Give udev a moment to remove stale device nodes
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle 2>/dev/null || true
    fi
    sleep 1

    return $unmounted
}

# Function to detach loop device
detach_loop_device() {
    local loop_device=$1
    local force=${2:-false}  # second optional argument: "true" to forcibly kill blockers

    print_info "Detaching $loop_device"

    # If the device is not present in losetup listing, consider it already detached
    if ! losetup -l -n -O NAME 2>/dev/null | awk '{print $1}' | grep -qxF "$loop_device"; then
        print_success "Loop device already detached"
        return 0
    fi

    # Try a normal detach first
    if losetup -d "$loop_device" 2>/dev/null; then
        print_success "Detached $loop_device"
        return 0
    fi

    print_warning "Initial detach failed for $loop_device; attempting recovery steps"

    # Try removing partition mappings and let udev settle
    if command -v partx >/dev/null 2>&1; then
        partx -d "$loop_device" 2>/dev/null || true
    elif command -v kpartx >/dev/null 2>&1; then
        kpartx -d "$loop_device" 2>/dev/null || true
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle 2>/dev/null || true
    fi
    sleep 1

    # Second detach attempt
    if losetup -d "$loop_device" 2>/dev/null; then
        print_success "Detached $loop_device"
        return 0
    fi

    # If allowed, try to kill processes referencing the loop device (SIGTERM then SIGKILL)
    if [ "$force" = "true" ]; then
        if command -v fuser >/dev/null 2>&1; then
            print_info "Killing processes using $loop_device (SIGTERM)"
            fuser -k -TERM "$loop_device" 2>/dev/null || true
            sleep 1

            # Try detach again
            if losetup -d "$loop_device" 2>/dev/null; then
                print_success "Detached $loop_device after killing blockers"
                return 0
            fi

            print_info "Killing any remaining processes using $loop_device (SIGKILL)"
            fuser -k -KILL "$loop_device" 2>/dev/null || true
            sleep 1

            if losetup -d "$loop_device" 2>/dev/null; then
                print_success "Detached $loop_device after force-killing blockers"
                return 0
            fi
        elif command -v lsof >/dev/null 2>&1; then
            print_info "Listing processes using $loop_device via lsof"
            lsof "$loop_device" 2>/dev/null || true
            local pids
            pids=$(lsof -t "$loop_device" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                print_info "Sending SIGTERM to: $pids"
                kill -TERM $pids 2>/dev/null || true
                sleep 1
                if losetup -d "$loop_device" 2>/dev/null; then
                    print_success "Detached $loop_device after killing blockers"
                    return 0
                fi
                print_info "Sending SIGKILL to: $pids"
                kill -KILL $pids 2>/dev/null || true
                sleep 1
                if losetup -d "$loop_device" 2>/dev/null; then
                    print_success "Detached $loop_device after force-killing blockers"
                    return 0
                fi
            fi
        else
            print_warning "No 'fuser' or 'lsof' available; cannot automatically kill blocking processes"
        fi
    fi

    print_error "Failed to detach $loop_device. The device is likely still referenced by processes or the kernel"
    print_info "Processes referencing $loop_device (if any):"
    list_blocking_processes "$loop_device"

    return 1
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
    read -p "Clean up all $count device(s)? (yes/no, default: no): " confirm
    confirm=${confirm:-no}

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
        unmount_loop_partitions "$device" || true

        # In automatic cleanup assume we are allowed to force-kill blockers when necessary
        if detach_loop_device "$device" "true"; then
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

    unmount_loop_partitions "$loop_device" || true

    # Ask user whether to force if needed
    read -p "Force-kill processes using $loop_device if necessary? (y/N): " force_ans
    force_ans=${force_ans:-N}
    if [ "$force_ans" = "y" ] || [ "$force_ans" = "Y" ]; then
        detach_loop_device "$loop_device" "true"
    else
        detach_loop_device "$loop_device"
    fi

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

    read -p "Enter selection (default: q): " selection
    selection=${selection:-q}

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

    unmount_loop_partitions "$device" || true

    read -p "Force-kill processes using $device if necessary? (y/N): " force_ans
    force_ans=${force_ans:-N}
    if [ "$force_ans" = "y" ] || [ "$force_ans" = "Y" ]; then
        detach_loop_device "$device" "true"
    else
        detach_loop_device "$device"
    fi

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
    read -p "Select option [1-4, default: 4]: " option
    option=${option:-4}
    
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