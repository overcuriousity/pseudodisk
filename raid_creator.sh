#!/bin/bash

# Universal Forensic RAID Creator
# Combines mdadm production arrays with manual implementation
# Supports both metadata-based and raw RAID configurations
# Version 2.0

set -e
set -o pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Global variables
INPUT_IMAGE=""
OUTPUT_PREFIX=""
RAID_LEVEL=""
NUM_DISKS=0
STRIPE_SIZE_KB=64
CHUNK_LAYOUT="left-symmetric"
STRIPE_DIRECTION="forward"
STRIPE_ALGORITHM="standard"
METADATA_VERSION="1.2"
SPARE_DISKS=0
DISK_SIZE_MB=0
COPY_METHOD="block"
FILESYSTEM=""
MD_DEVICE=""
LOOP_DEVICES=()
PRESERVE_ARRAY=false
USE_MDADM=true
IMPLEMENTATION_MODE=""

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_note() { echo -e "${CYAN}[NOTE]${NC} $1"; }
print_tip() { echo -e "${MAGENTA}[TIP]${NC} $1"; }

# Banner
show_banner() {
    echo ""
    echo "=========================================="
    echo "  Universal Forensic RAID Creator"
    echo "  Production & Educational RAID Arrays"
    echo "  v2.0"
    echo "=========================================="
    echo ""
    print_note "Supports both mdadm and manual implementations"
    echo ""
}

# Check root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    local missing=()
    local optional_missing=()
    
    # Essential tools
    command -v dd >/dev/null 2>&1 || missing+=("coreutils")
    command -v bc >/dev/null 2>&1 || missing+=("bc")
    command -v losetup >/dev/null 2>&1 || missing+=("util-linux")
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required packages: ${missing[*]}"
        print_info "Install with: sudo apt-get install ${missing[*]}"
        exit 1
    fi
    
    # Check mdadm (optional but recommended)
    if ! command -v mdadm >/dev/null 2>&1; then
        optional_missing+=("mdadm")
        print_warning "mdadm not found - only manual mode will be available"
        USE_MDADM=false
    fi
    
    # Check parity calculation tools for manual mode
    local has_parity_tools=false
    command -v python3 >/dev/null 2>&1 && has_parity_tools=true
    command -v gcc >/dev/null 2>&1 && has_parity_tools=true
    command -v perl >/dev/null 2>&1 && has_parity_tools=true
    
    if [ "$has_parity_tools" = false ]; then
        print_warning "No parity calculation tools (python3/gcc/perl) - RAID 5/6 manual mode unavailable"
    fi
    
    if [ ${#optional_missing[@]} -gt 0 ]; then
        print_info "Optional packages not installed: ${optional_missing[*]}"
        print_tip "Install mdadm for production RAID: sudo apt-get install mdadm"
    fi
    
    print_success "Dependency check complete"
}

# Get implementation mode
get_implementation_mode() {
    echo ""
    echo "=========================================="
    echo "  RAID Implementation Mode"
    echo "=========================================="
    echo ""
    echo "Choose how to create the RAID array:"
    echo ""
    
    if command -v mdadm >/dev/null 2>&1; then
        echo "  1) mdadm (Production)"
        echo "     • Real RAID metadata and superblocks"
        echo "     • Can be mounted and analyzed with standard tools"
        echo "     • Most realistic for forensic practice"
        echo "     • Faster creation"
        echo ""
        echo "  2) Manual (Educational)"
        echo "     • No RAID metadata - raw striping/parity"
        echo "     • Shows internal RAID mechanics"
        echo "     • More configuration options"
        echo "     • Requires manual reassembly with mdadm"
        echo ""
        echo "  3) Hybrid (Both)"
        echo "     • Create manual layout first"
        echo "     • Then add mdadm metadata"
        echo "     • Best of both worlds"
        echo ""
        read -p "Select mode [1-3]: " choice
    else
        echo "  2) Manual (Educational) - ONLY OPTION"
        echo "     • mdadm not installed"
        echo "     • No RAID metadata - raw striping/parity"
        echo "     • Shows internal RAID mechanics"
        echo ""
        choice=2
    fi
    
    case $choice in
        1)
            IMPLEMENTATION_MODE="mdadm"
            print_info "Using mdadm (production mode)"
            ;;
        2)
            IMPLEMENTATION_MODE="manual"
            print_info "Using manual implementation (educational mode)"
            ;;
        3)
            IMPLEMENTATION_MODE="hybrid"
            print_info "Using hybrid mode (manual + mdadm metadata)"
            ;;
        *)
            print_error "Invalid choice"
            get_implementation_mode
            return
            ;;
    esac
}

# Get input image
get_input_image() {
    echo ""
    read -p "Enter input disk image path (default: forensic_disk.dd): " INPUT_IMAGE
    INPUT_IMAGE=${INPUT_IMAGE:-forensic_disk.dd}
    INPUT_IMAGE=$(echo "$INPUT_IMAGE" | xargs)
    
    if [ ! -f "$INPUT_IMAGE" ]; then
        print_error "File not found: $INPUT_IMAGE"
        get_input_image
        return
    fi
    
    if [ ! -r "$INPUT_IMAGE" ]; then
        print_error "File not readable: $INPUT_IMAGE"
        get_input_image
        return
    fi
    
    local size_bytes=$(stat -c%s "$INPUT_IMAGE" 2>/dev/null || stat -f%z "$INPUT_IMAGE" 2>/dev/null)
    local size_mb=$((size_bytes / 1024 / 1024))
    DISK_SIZE_MB=$size_mb
    
    print_success "Input: $INPUT_IMAGE (${size_mb} MB)"
}

# Get output prefix
get_output_prefix() {
    echo ""
    read -p "Enter output filename prefix (default: raid_disk): " OUTPUT_PREFIX
    OUTPUT_PREFIX=${OUTPUT_PREFIX:-raid_disk}
    OUTPUT_PREFIX=$(echo "$OUTPUT_PREFIX" | xargs)
    
    if [[ ! "$OUTPUT_PREFIX" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_error "Prefix can only contain: letters, numbers, dots, underscores, hyphens"
        get_output_prefix
        return
    fi
    
    print_info "Output files: ${OUTPUT_PREFIX}_0.dd, ${OUTPUT_PREFIX}_1.dd, etc."
}

# Show RAID info
show_raid_info() {
    echo ""
    echo "=========================================="
    echo "  RAID Level Information"
    echo "=========================================="
    echo ""
    echo "RAID 0 (Striping):"
    echo "  - Maximum performance, no redundancy"
    echo "  - Min disks: 2, Capacity: N × size"
    echo ""
    echo "RAID 1 (Mirroring):"
    echo "  - Full redundancy, all disks identical"
    echo "  - Min disks: 2, Capacity: 1 × size"
    echo ""
    echo "RAID 4 (Striping with Dedicated Parity):"
    echo "  - Dedicated parity disk (rarely used)"
    echo "  - Min disks: 3, Capacity: (N-1) × size"
    echo ""
    echo "RAID 5 (Striping with Distributed Parity):"
    echo "  - Parity distributed across all disks"
    echo "  - Min disks: 3, Capacity: (N-1) × size"
    echo "  - Survives: 1 disk failure"
    echo ""
    echo "RAID 6 (Striping with Double Parity):"
    echo "  - Two parity blocks per stripe"
    echo "  - Min disks: 4, Capacity: (N-2) × size"
    echo "  - Survives: 2 disk failures"
    echo ""
    echo "RAID 10 (Mirror + Stripe):"
    echo "  - Nested RAID 1+0"
    echo "  - Min disks: 4 (even), Capacity: N/2 × size"
    echo "  - Survives: 1 disk per mirror pair"
    echo ""
}

# Get RAID level
get_raid_level() {
    show_raid_info
    
    echo "Select RAID Level:"
    echo "  1) RAID 0  (Striping)"
    echo "  2) RAID 1  (Mirroring)"
    if [ "$IMPLEMENTATION_MODE" = "mdadm" ] || [ "$IMPLEMENTATION_MODE" = "hybrid" ]; then
        echo "  3) RAID 4  (Dedicated Parity)"
    fi
    echo "  4) RAID 5  (Distributed Parity)"
    echo "  5) RAID 6  (Double Parity)"
    echo "  6) RAID 10 (Mirror + Stripe)"
    echo ""
    read -p "Select RAID level [1-6, default: 5]: " choice
    choice=${choice:-5}
    
    case $choice in
        1) RAID_LEVEL="0" ;;
        2) RAID_LEVEL="1" ;;
        3)
            if [ "$IMPLEMENTATION_MODE" = "mdadm" ] || [ "$IMPLEMENTATION_MODE" = "hybrid" ]; then
                RAID_LEVEL="4"
            else
                print_error "RAID 4 only available in mdadm mode"
                get_raid_level
                return
            fi
            ;;
        4) RAID_LEVEL="5" ;;
        5) RAID_LEVEL="6" ;;
        6) RAID_LEVEL="10" ;;
        *)
            print_error "Invalid choice"
            get_raid_level
            return
            ;;
    esac
    
    print_info "RAID $RAID_LEVEL selected"
}

# Get number of disks
get_num_disks() {
    local min_disks=2
    
    case $RAID_LEVEL in
        0|1) min_disks=2 ;;
        4|5) min_disks=3 ;;
        6) min_disks=4 ;;
        10)
            min_disks=4
            print_note "RAID 10 requires an even number of disks"
            ;;
    esac
    
    echo ""
    read -p "Enter number of disks (${min_disks}-16, default: ${min_disks}): " NUM_DISKS
    NUM_DISKS=${NUM_DISKS:-${min_disks}}
    
    if ! [[ "$NUM_DISKS" =~ ^[0-9]+$ ]] || [ "$NUM_DISKS" -lt "$min_disks" ] || [ "$NUM_DISKS" -gt 16 ]; then
        print_error "Invalid number (must be ${min_disks}-16)"
        get_num_disks
        return
    fi
    
    if [ "$RAID_LEVEL" = "10" ] && [ $((NUM_DISKS % 2)) -ne 0 ]; then
        print_error "RAID 10 requires even number of disks"
        get_num_disks
        return
    fi
    
    print_success "Using $NUM_DISKS disks"
}

# Get spare disks (mdadm only)
get_spare_disks() {
    if [ "$IMPLEMENTATION_MODE" != "mdadm" ] && [ "$IMPLEMENTATION_MODE" != "hybrid" ]; then
        SPARE_DISKS=0
        return
    fi
    
    if [ "$RAID_LEVEL" = "0" ] || [ "$RAID_LEVEL" = "1" ]; then
        SPARE_DISKS=0
        return
    fi
    
    echo ""
    echo "Hot spare disks can be used for automatic rebuilds (mdadm only)"
    read -p "Add spare disks? (0-2, default: 0): " SPARE_DISKS
    SPARE_DISKS=${SPARE_DISKS:-0}
    
    if ! [[ "$SPARE_DISKS" =~ ^[0-9]+$ ]] || [ "$SPARE_DISKS" -gt 2 ]; then
        print_error "Invalid number (0-2)"
        get_spare_disks
        return
    fi
    
    if [ "$SPARE_DISKS" -gt 0 ]; then
        print_info "Adding $SPARE_DISKS spare disk(s)"
    fi
}

# Get stripe size
get_stripe_size() {
    if [ "$RAID_LEVEL" = "1" ]; then
        print_note "RAID 1 does not use striping"
        return
    fi
    
    echo ""
    echo "Chunk/Stripe Size:"
    echo "  1) 4 KB"
    echo "  2) 8 KB"
    echo "  3) 16 KB"
    echo "  4) 32 KB"
    echo "  5) 64 KB   (default)"
    echo "  6) 128 KB"
    echo "  7) 256 KB"
    echo "  8) 512 KB"
    echo "  9) 1024 KB (1 MB)"
    echo ""
    read -p "Select chunk size [1-9, default: 5]: " choice
    choice=${choice:-5}
    
    case $choice in
        1) STRIPE_SIZE_KB=4 ;;
        2) STRIPE_SIZE_KB=8 ;;
        3) STRIPE_SIZE_KB=16 ;;
        4) STRIPE_SIZE_KB=32 ;;
        5) STRIPE_SIZE_KB=64 ;;
        6) STRIPE_SIZE_KB=128 ;;
        7) STRIPE_SIZE_KB=256 ;;
        8) STRIPE_SIZE_KB=512 ;;
        9) STRIPE_SIZE_KB=1024 ;;
        *)
            print_error "Invalid choice"
            get_stripe_size
            return
            ;;
    esac
    
    print_info "Chunk size: ${STRIPE_SIZE_KB} KB"
}

# Get stripe direction (manual mode)
get_stripe_direction() {
    if [ "$IMPLEMENTATION_MODE" = "mdadm" ]; then
        STRIPE_DIRECTION="forward"
        return
    fi
    
    if [ "$RAID_LEVEL" = "1" ]; then
        return
    fi
    
    echo ""
    echo "Stripe Direction:"
    echo "  1) Forward (left-to-right, disk 0 → disk N) - standard"
    echo "  2) Backward (right-to-left, disk N → disk 0)"
    echo "  3) Inside-out (center outward)"
    echo "  4) Outside-in (edges toward center)"
    echo ""
    print_note "Forward is standard for all RAID implementations"
    echo ""
    read -p "Select stripe direction [1-4, default: 1]: " choice
    choice=${choice:-1}
    
    case $choice in
        1)
            STRIPE_DIRECTION="forward"
            print_info "Stripe direction: Forward (standard)"
            ;;
        2)
            STRIPE_DIRECTION="backward"
            print_info "Stripe direction: Backward"
            print_warning "Non-standard - educational only"
            ;;
        3)
            STRIPE_DIRECTION="inside-out"
            print_info "Stripe direction: Inside-out"
            print_warning "Non-standard - educational only"
            ;;
        4)
            STRIPE_DIRECTION="outside-in"
            print_info "Stripe direction: Outside-in"
            print_warning "Non-standard - educational only"
            ;;
        *)
            print_error "Invalid choice"
            get_stripe_direction
            return
            ;;
    esac
}

# Get stripe algorithm (manual mode advanced)
get_stripe_algorithm() {
    if [ "$IMPLEMENTATION_MODE" = "mdadm" ]; then
        STRIPE_ALGORITHM="standard"
        return
    fi
    
    if [ "$RAID_LEVEL" = "1" ] || [ "$RAID_LEVEL" = "10" ]; then
        return
    fi
    
    echo ""
    echo "Stripe Algorithm (Advanced):"
    echo "  1) Standard (sequential striping)"
    echo "  2) Delayed (offset by half stripe)"
    echo "  3) Interleaved (alternating pattern)"
    echo "  4) Random (pseudo-random distribution)"
    echo ""
    print_tip "Standard is used by all production systems"
    echo ""
    read -p "Select algorithm [1-4, default: 1]: " choice
    choice=${choice:-1}
    
    case $choice in
        1)
            STRIPE_ALGORITHM="standard"
            print_info "Algorithm: Standard"
            ;;
        2)
            STRIPE_ALGORITHM="delayed"
            print_info "Algorithm: Delayed"
            print_warning "Educational only - non-standard"
            ;;
        3)
            STRIPE_ALGORITHM="interleaved"
            print_info "Algorithm: Interleaved"
            print_warning "Educational only - non-standard"
            ;;
        4)
            STRIPE_ALGORITHM="random"
            print_info "Algorithm: Random"
            print_warning "Educational only - adds unpredictability"
            ;;
        *)
            print_error "Invalid choice"
            get_stripe_algorithm
            return
            ;;
    esac
}

# Get layout/algorithm
get_raid_layout() {
    if [ "$RAID_LEVEL" != "5" ] && [ "$RAID_LEVEL" != "6" ] && [ "$RAID_LEVEL" != "10" ]; then
        return
    fi
    
    echo ""
    
    if [ "$RAID_LEVEL" = "5" ] || [ "$RAID_LEVEL" = "6" ]; then
        echo "RAID $RAID_LEVEL Parity Layout Algorithm:"
        echo "  1) left-symmetric      (default, most common)"
        echo "  2) left-asymmetric"
        echo "  3) right-symmetric"
        echo "  4) right-asymmetric"
        
        if [ "$IMPLEMENTATION_MODE" = "mdadm" ] || [ "$IMPLEMENTATION_MODE" = "hybrid" ]; then
            echo "  5) parity-first        (RAID 4-style)"
            echo "  6) parity-last"
            if [ "$RAID_LEVEL" = "6" ]; then
                echo "  7) left-symmetric-6    (RAID 6 optimized)"
                echo "  8) right-symmetric-6"
            fi
        fi
        echo ""
        print_tip "left-symmetric is Linux MD default"
        echo ""
        read -p "Select layout [1-8, default: 1]: " choice
        choice=${choice:-1}
        
        case $choice in
            1) CHUNK_LAYOUT="left-symmetric" ;;
            2) CHUNK_LAYOUT="left-asymmetric" ;;
            3) CHUNK_LAYOUT="right-symmetric" ;;
            4) CHUNK_LAYOUT="right-asymmetric" ;;
            5) CHUNK_LAYOUT="parity-first" ;;
            6) CHUNK_LAYOUT="parity-last" ;;
            7) CHUNK_LAYOUT="left-symmetric-6" ;;
            8) CHUNK_LAYOUT="right-symmetric-6" ;;
            *)
                print_error "Invalid choice"
                get_raid_layout
                return
                ;;
        esac
    elif [ "$RAID_LEVEL" = "10" ]; then
        if [ "$IMPLEMENTATION_MODE" = "mdadm" ] || [ "$IMPLEMENTATION_MODE" = "hybrid" ]; then
            echo "RAID 10 Layout Algorithm:"
            echo "  1) near (n2)       - default, mirrored chunks nearby"
            echo "  2) far (f2)        - mirrored chunks far apart"
            echo "  3) offset (o2)     - offset striping pattern"
            echo ""
            read -p "Select layout [1-3, default: 1]: " choice
            choice=${choice:-1}
            
            case $choice in
                1) CHUNK_LAYOUT="n2" ;;
                2) CHUNK_LAYOUT="f2" ;;
                3) CHUNK_LAYOUT="o2" ;;
                *)
                    print_error "Invalid choice"
                    get_raid_layout
                    return
                    ;;
            esac
        else
            CHUNK_LAYOUT="near"
        fi
    fi
    
    print_info "Layout: $CHUNK_LAYOUT"
}

# Get metadata version (mdadm only)
get_metadata_version() {
    if [ "$IMPLEMENTATION_MODE" = "manual" ]; then
        print_note "Manual mode: No metadata/superblocks will be created"
        return
    fi
    
    echo ""
    echo "RAID Metadata Version:"
    echo "  1) 1.2  (default, at start of device)"
    echo "  2) 1.1  (at end of device)"
    echo "  3) 1.0  (legacy, end of device)"
    echo "  4) 0.90 (very old, limited features)"
    echo ""
    print_tip "1.2 is recommended for modern systems"
    if [ "$RAID_LEVEL" = "6" ]; then
        print_warning "RAID 6 works best with metadata 1.0 or newer"
    fi
    echo ""
    read -p "Select metadata version [1-4, default: 1]: " choice
    choice=${choice:-1}
    
    case $choice in
        1) METADATA_VERSION="1.2" ;;
        2) METADATA_VERSION="1.1" ;;
        3) METADATA_VERSION="1.0" ;;
        4) 
            METADATA_VERSION="0.90"
            if [ "$RAID_LEVEL" = "6" ]; then
                print_warning "Metadata 0.90 has limitations with RAID 6, using 1.2 instead"
                METADATA_VERSION="1.2"
            fi
            ;;
        *)
            print_error "Invalid choice"
            get_metadata_version
            return
            ;;
    esac
    
    print_info "Metadata version: $METADATA_VERSION"
}

# Get copy method (mdadm only)
get_copy_method() {
    if [ "$IMPLEMENTATION_MODE" != "mdadm" ]; then
        COPY_METHOD="block"
        return
    fi
    
    echo ""
    echo "Data Copy Method:"
    echo "  1) Block-level copy (dd entire image to RAID)"
    echo "  2) Filesystem copy (mount both, copy files)"
    echo ""
    print_note "Block-level preserves everything including free space"
    print_note "Filesystem copy only copies actual files"
    echo ""
    read -p "Select copy method [1-2, default: 1]: " choice
    choice=${choice:-1}
    
    case $choice in
        1)
            COPY_METHOD="block"
            print_info "Will use block-level copy (dd)"
            ;;
        2)
            COPY_METHOD="filesystem"
            print_info "Will use filesystem-level copy"
            get_filesystem
            ;;
        *)
            print_error "Invalid choice"
            get_copy_method
            return
            ;;
    esac
}

# Get filesystem (if needed)
get_filesystem() {
    echo ""
    echo "Filesystem for RAID array:"
    echo "  1) ext4"
    echo "  2) ext3"
    echo "  3) xfs"
    echo "  4) btrfs"
    echo ""
    read -p "Select filesystem [1-4, default: 1]: " choice
    choice=${choice:-1}
    
    case $choice in
        1) FILESYSTEM="ext4" ;;
        2) FILESYSTEM="ext3" ;;
        3) FILESYSTEM="xfs" ;;
        4) FILESYSTEM="btrfs" ;;
        *)
            print_error "Invalid choice"
            get_filesystem
            return
            ;;
    esac
    
    print_info "Filesystem: $FILESYSTEM"
}

# Calculate disk position based on direction and algorithm
calculate_disk_position() {
    local stripe_num=$1
    local num_disks=$2
    local direction=$3
    local algorithm=$4
    
    local base_disk=$((stripe_num % num_disks))
    
    case $direction in
        forward)
            echo $base_disk
            ;;
        backward)
            echo $(( (num_disks - 1) - base_disk ))
            ;;
        inside-out)
            local mid=$((num_disks / 2))
            if [ $((stripe_num % 2)) -eq 0 ]; then
                echo $(( mid + (stripe_num / 2) % (num_disks - mid) ))
            else
                echo $(( mid - 1 - (stripe_num / 2) % mid ))
            fi
            ;;
        outside-in)
            if [ $((stripe_num % 2)) -eq 0 ]; then
                echo $(( (stripe_num / 2) % num_disks ))
            else
                echo $(( num_disks - 1 - (stripe_num / 2) % num_disks ))
            fi
            ;;
        *)
            echo $base_disk
            ;;
    esac
}

# Apply stripe algorithm offset
apply_stripe_algorithm() {
    local stripe_num=$1
    local algorithm=$2
    
    case $algorithm in
        standard)
            echo $stripe_num
            ;;
        delayed)
            echo $((stripe_num + (NUM_DISKS / 2)))
            ;;
        interleaved)
            if [ $((stripe_num % 2)) -eq 0 ]; then
                echo $stripe_num
            else
                echo $((stripe_num + NUM_DISKS))
            fi
            ;;
        random)
            # Pseudo-random but deterministic
            echo $(( (stripe_num * 2654435761) % 4294967296 ))
            ;;
        *)
            echo $stripe_num
            ;;
    esac
}

# Calculate XOR parity for RAID 5
calculate_parity() {
    local -a chunk_files=("$@")
    local parity_file="${chunk_files[-1]}"
    unset 'chunk_files[-1]'
    
    if [ ${#chunk_files[@]} -eq 0 ]; then
        print_error "No input chunks provided for parity calculation"
        return 1
    fi
    
    for cf in "${chunk_files[@]}"; do
        if [ ! -f "$cf" ]; then
            print_error "Input chunk file not found: $cf"
            return 1
        fi
    done
    
    if [ -s "${chunk_files[0]}" ]; then
        if ! cp "${chunk_files[0]}" "$parity_file" 2>/dev/null; then
            print_error "Failed to initialize parity file"
            return 1
        fi
    else
        touch "$parity_file"
    fi
    
    if command -v python3 >/dev/null 2>&1; then
        for ((i=1; i<${#chunk_files[@]}; i++)); do
            python3 -c "
import sys
try:
    with open('$parity_file', 'rb') as pf, open('${chunk_files[$i]}', 'rb') as cf:
        parity = bytearray(pf.read())
        chunk = bytearray(cf.read())
        max_len = max(len(parity), len(chunk))
        if len(chunk) < max_len:
            chunk.extend([0] * (max_len - len(chunk)))
        if len(parity) < max_len:
            parity.extend([0] * (max_len - len(parity)))
        result = bytearray(a ^ b for a, b in zip(parity, chunk))
    with open('$parity_file', 'wb') as pf:
        pf.write(result)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" || return 1
        done
    else
        print_error "Python3 required for parity calculation"
        return 1
    fi
    
    return 0
}

# Calculate Reed-Solomon Q parity for RAID 6
calculate_q_parity() {
    local -a chunk_files=("$@")
    local q_parity_file="${chunk_files[-1]}"
    unset 'chunk_files[-1]'
    
    if [ ${#chunk_files[@]} -eq 0 ]; then
        print_error "No input chunks provided for Q parity calculation"
        return 1
    fi
    
    for cf in "${chunk_files[@]}"; do
        if [ ! -f "$cf" ]; then
            print_error "Input chunk file not found: $cf"
            return 1
        fi
    done
    
    if command -v python3 >/dev/null 2>&1; then
        local python_file_list=""
        for cf in "${chunk_files[@]}"; do
            local escaped_cf="${cf//\'/\'\\\'\'}"
            python_file_list="${python_file_list}'${escaped_cf}', "
        done
        python_file_list="[${python_file_list%, }]"
        
        python3 -c "
import sys
def gf_mult(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi_bit = a & 0x80
        a <<= 1
        if hi_bit:
            a ^= 0x1d
        a &= 0xff
        b >>= 1
    return p

try:
    chunk_files = $python_file_list
    chunks = []
    for cf in chunk_files:
        with open(cf, 'rb') as f:
            chunks.append(bytearray(f.read()))
    
    max_len = max(len(c) for c in chunks) if chunks else 0
    for c in chunks:
        if len(c) < max_len:
            c.extend([0] * (max_len - len(c)))
    
    q_parity = bytearray(max_len)
    for i in range(max_len):
        for j, chunk in enumerate(chunks):
            coeff = 2 ** j if j < 8 else (2 ** (j % 8))
            q_parity[i] ^= gf_mult(chunk[i], coeff)
    
    with open('$q_parity_file', 'wb') as f:
        f.write(q_parity)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" || return 1
    else
        print_warning "Python not available - using simplified Q parity (XOR approximation)"
        calculate_parity "${chunk_files[@]}" "$q_parity_file" || return 1
    fi
    
    return 0
}

# Create disk images
create_disk_images() {
    print_info "Creating ${NUM_DISKS} disk images (${DISK_SIZE_MB} MB each)..."
    
    local total_disks=$((NUM_DISKS + SPARE_DISKS))
    
    for ((i=0; i<total_disks; i++)); do
        local disk_file="${OUTPUT_PREFIX}_${i}.dd"
        
        if [ -f "$disk_file" ]; then
            print_warning "File exists: $disk_file"
            read -p "Overwrite? (y/n, default: n): " overwrite
            overwrite=${overwrite:-n}
            if [ "$overwrite" != "y" ]; then
                print_error "Cannot proceed with existing files"
                exit 1
            fi
        fi
        
        print_info "Creating disk $i: $disk_file"
        dd if=/dev/zero of="$disk_file" bs=1M count="$DISK_SIZE_MB" status=none
        
        if [ ! -f "$disk_file" ]; then
            print_error "Failed to create $disk_file"
            exit 1
        fi
    done
    
    print_success "All disk images created"
}

# Manual RAID 0 implementation
create_raid0_manual() {
    print_info "Creating RAID 0 array (manual striping)..."
    
    local input_size=$(stat -c%s "$INPUT_IMAGE")
    local stripe_bytes=$((STRIPE_SIZE_KB * 1024))
    local num_stripes=$(( (input_size + stripe_bytes - 1) / stripe_bytes ))
    
    print_info "Total stripes: $num_stripes"
    print_info "Stripe size: ${STRIPE_SIZE_KB} KB"
    print_info "Direction: $STRIPE_DIRECTION"
    print_info "Algorithm: $STRIPE_ALGORITHM"
    
    local stripe_num=0
    local offset=0
    
    while [ $offset -lt $input_size ]; do
        local adjusted_stripe=$(apply_stripe_algorithm $stripe_num "$STRIPE_ALGORITHM")
        local disk=$(calculate_disk_position $adjusted_stripe $NUM_DISKS "$STRIPE_DIRECTION" "$STRIPE_ALGORITHM")
        
        local disk_file="${OUTPUT_PREFIX}_${disk}.dd"
        local disk_offset=$(( (stripe_num / NUM_DISKS) * stripe_bytes ))
        
        dd if="$INPUT_IMAGE" of="$disk_file" bs=$stripe_bytes \
           skip=$stripe_num count=1 seek=$((disk_offset / stripe_bytes)) \
           conv=notrunc status=none 2>/dev/null || true
        
        offset=$((offset + stripe_bytes))
        stripe_num=$((stripe_num + 1))
        
        if [ $((stripe_num % 100)) -eq 0 ]; then
            local percent=$(( (offset * 100) / input_size ))
            echo -ne "\rProgress: ${percent}%"
        fi
    done
    echo ""
    
    print_success "RAID 0 array created"
}

# Manual RAID 1 implementation
create_raid1_manual() {
    print_info "Creating RAID 1 array (mirroring)..."
    
    for ((disk=0; disk<NUM_DISKS; disk++)); do
        local disk_file="${OUTPUT_PREFIX}_${disk}.dd"
        print_info "Creating mirror $disk: $disk_file"
        cp "$INPUT_IMAGE" "$disk_file"
    done
    
    print_success "RAID 1 array created (all disks are identical)"
}

# Manual RAID 5 implementation
create_raid5_manual() {
    print_info "Creating RAID 5 array (manual striping with parity)..."
    
    local input_size=$(stat -c%s "$INPUT_IMAGE")
    local stripe_bytes=$((STRIPE_SIZE_KB * 1024))
    local data_disks=$((NUM_DISKS - 1))
    local stripe_set_size=$((stripe_bytes * data_disks))
    
    print_info "Data disks: $data_disks"
    print_info "Stripe size: ${STRIPE_SIZE_KB} KB"
    print_info "Layout: $CHUNK_LAYOUT"
    print_info "Direction: $STRIPE_DIRECTION"
    
    local temp_dir="/tmp/raid5_chunks_$$"
    mkdir -p "$temp_dir"
    
    print_info "Distributing data with rotating parity..."
    local stripe_set=0
    local offset=0
    
    while [ $offset -lt $input_size ]; do
        local parity_disk
        case $CHUNK_LAYOUT in
            left-symmetric)
                parity_disk=$((NUM_DISKS - 1 - (stripe_set % NUM_DISKS)))
                ;;
            left-asymmetric)
                parity_disk=$((stripe_set % NUM_DISKS))
                ;;
            right-symmetric)
                parity_disk=$((stripe_set % NUM_DISKS))
                ;;
            right-asymmetric)
                parity_disk=$((NUM_DISKS - 1 - (stripe_set % NUM_DISKS)))
                ;;
        esac
        
        local -a chunk_files=()
        local data_chunk=0
        
        for ((disk=0; disk<NUM_DISKS; disk++)); do
            if [ $disk -eq $parity_disk ]; then
                continue
            fi
            
            local disk_file="${OUTPUT_PREFIX}_${disk}.dd"
            local chunk_file="$temp_dir/chunk_${stripe_set}_${data_chunk}.tmp"
            
            dd if="$INPUT_IMAGE" of="$chunk_file" bs=$stripe_bytes \
               skip=$((stripe_set * data_disks + data_chunk)) count=1 status=none 2>/dev/null || true
            
            dd if="$chunk_file" of="$disk_file" bs=$stripe_bytes \
               seek=$stripe_set count=1 conv=notrunc status=none 2>/dev/null || true
            
            chunk_files+=("$chunk_file")
            data_chunk=$((data_chunk + 1))
        done
        
        local parity_file="$temp_dir/parity_${stripe_set}.tmp"
        chunk_files+=("$parity_file")
        
        if [ ${#chunk_files[@]} -gt 1 ]; then
            calculate_parity "${chunk_files[@]}" || {
                print_error "Parity calculation failed at stripe set $stripe_set"
                rm -rf "$temp_dir"
                exit 1
            }
            
            dd if="$parity_file" of="${OUTPUT_PREFIX}_${parity_disk}.dd" \
               bs=$stripe_bytes seek=$stripe_set count=1 conv=notrunc status=none 2>/dev/null || true
        fi
        
        offset=$((offset + stripe_set_size))
        stripe_set=$((stripe_set + 1))
        
        if [ $((stripe_set % 10)) -eq 0 ]; then
            local percent=$(( (offset * 100) / input_size ))
            echo -ne "\rProgress: ${percent}%"
        fi
    done
    echo ""
    
    rm -rf "$temp_dir"
    print_success "RAID 5 array created with rotating parity"
}

# Manual RAID 6 implementation
create_raid6_manual() {
    print_info "Creating RAID 6 array (manual striping with double parity)..."
    
    local input_size=$(stat -c%s "$INPUT_IMAGE")
    local stripe_bytes=$((STRIPE_SIZE_KB * 1024))
    local data_disks=$((NUM_DISKS - 2))
    local stripe_set_size=$((stripe_bytes * data_disks))
    
    print_info "Data disks: $data_disks"
    print_info "Stripe size: ${STRIPE_SIZE_KB} KB"
    print_info "Layout: $CHUNK_LAYOUT (with Q parity)"
    
    local temp_dir="/tmp/raid6_chunks_$$"
    mkdir -p "$temp_dir"
    
    print_info "Distributing data with dual rotating parity (P+Q)..."
    local stripe_set=0
    local offset=0
    
    while [ $offset -lt $input_size ]; do
        local p_parity_disk q_parity_disk
        case $CHUNK_LAYOUT in
            left-symmetric)
                p_parity_disk=$((NUM_DISKS - 1 - (stripe_set % NUM_DISKS)))
                q_parity_disk=$(( (p_parity_disk + NUM_DISKS - 1) % NUM_DISKS ))
                ;;
            left-asymmetric)
                p_parity_disk=$((stripe_set % NUM_DISKS))
                q_parity_disk=$(( (p_parity_disk + 1) % NUM_DISKS ))
                ;;
            right-symmetric)
                p_parity_disk=$((stripe_set % NUM_DISKS))
                q_parity_disk=$(( (p_parity_disk + 1) % NUM_DISKS ))
                ;;
            right-asymmetric)
                p_parity_disk=$((NUM_DISKS - 1 - (stripe_set % NUM_DISKS)))
                q_parity_disk=$(( (p_parity_disk + NUM_DISKS - 1) % NUM_DISKS ))
                ;;
        esac
        
        local -a chunk_files_p=()
        local -a chunk_files_q=()
        local data_chunk=0
        
        for ((disk=0; disk<NUM_DISKS; disk++)); do
            if [ $disk -eq $p_parity_disk ] || [ $disk -eq $q_parity_disk ]; then
                continue
            fi
            
            local disk_file="${OUTPUT_PREFIX}_${disk}.dd"
            local chunk_file="$temp_dir/chunk_${stripe_set}_${data_chunk}.tmp"
            
            dd if="$INPUT_IMAGE" of="$chunk_file" bs=$stripe_bytes \
               skip=$((stripe_set * data_disks + data_chunk)) count=1 status=none 2>/dev/null || true
            
            dd if="$chunk_file" of="$disk_file" bs=$stripe_bytes \
               seek=$stripe_set count=1 conv=notrunc status=none 2>/dev/null || true
            
            chunk_files_p+=("$chunk_file")
            chunk_files_q+=("$chunk_file")
            data_chunk=$((data_chunk + 1))
        done
        
        local p_parity_file="$temp_dir/p_parity_${stripe_set}.tmp"
        local q_parity_file="$temp_dir/q_parity_${stripe_set}.tmp"
        chunk_files_p+=("$p_parity_file")
        chunk_files_q+=("$q_parity_file")
        
        if [ ${#chunk_files_p[@]} -gt 1 ]; then
            calculate_parity "${chunk_files_p[@]}" || {
                print_error "P parity calculation failed"
                rm -rf "$temp_dir"
                exit 1
            }
            dd if="$p_parity_file" of="${OUTPUT_PREFIX}_${p_parity_disk}.dd" \
               bs=$stripe_bytes seek=$stripe_set count=1 conv=notrunc status=none 2>/dev/null || true
        fi
        
        if [ ${#chunk_files_q[@]} -gt 1 ]; then
            calculate_q_parity "${chunk_files_q[@]}" || {
                print_error "Q parity calculation failed"
                rm -rf "$temp_dir"
                exit 1
            }
            dd if="$q_parity_file" of="${OUTPUT_PREFIX}_${q_parity_disk}.dd" \
               bs=$stripe_bytes seek=$stripe_set count=1 conv=notrunc status=none 2>/dev/null || true
        fi
        
        offset=$((offset + stripe_set_size))
        stripe_set=$((stripe_set + 1))
        
        if [ $((stripe_set % 10)) -eq 0 ]; then
            local percent=$(( (offset * 100) / input_size ))
            echo -ne "\rProgress: ${percent}%"
        fi
    done
    echo ""
    
    rm -rf "$temp_dir"
    print_success "RAID 6 array created with P+Q parity"
}

# Manual RAID 10 implementation
create_raid10_manual() {
    print_info "Creating RAID 10 array (mirroring + striping)..."
    
    local input_size=$(stat -c%s "$INPUT_IMAGE")
    local stripe_bytes=$((STRIPE_SIZE_KB * 1024))
    local mirror_pairs=$((NUM_DISKS / 2))
    
    print_info "Mirror pairs: $mirror_pairs"
    print_info "Stripe size: ${STRIPE_SIZE_KB} KB"
    
    local stripe_num=0
    local offset=0
    
    while [ $offset -lt $input_size ]; do
        local pair_num=$((stripe_num % mirror_pairs))
        local disk_primary=$((pair_num * 2))
        local disk_mirror=$((pair_num * 2 + 1))
        
        local disk_offset=$(( (stripe_num / mirror_pairs) * stripe_bytes ))
        
        dd if="$INPUT_IMAGE" of="${OUTPUT_PREFIX}_${disk_primary}.dd" \
           bs=$stripe_bytes skip=$stripe_num count=1 \
           seek=$((disk_offset / stripe_bytes)) conv=notrunc status=none 2>/dev/null || true
        
        dd if="$INPUT_IMAGE" of="${OUTPUT_PREFIX}_${disk_mirror}.dd" \
           bs=$stripe_bytes skip=$stripe_num count=1 \
           seek=$((disk_offset / stripe_bytes)) conv=notrunc status=none 2>/dev/null || true
        
        offset=$((offset + stripe_bytes))
        stripe_num=$((stripe_num + 1))
        
        if [ $((stripe_num % 100)) -eq 0 ]; then
            local percent=$(( (offset * 100) / input_size ))
            echo -ne "\rProgress: ${percent}%"
        fi
    done
    echo ""
    
    print_success "RAID 10 array created"
}

# Setup loop devices
setup_loop_devices() {
    print_info "Setting up loop devices..."
    
    local total_disks=$((NUM_DISKS + SPARE_DISKS))
    LOOP_DEVICES=()
    
    for ((i=0; i<total_disks; i++)); do
        local disk_file="${OUTPUT_PREFIX}_${i}.dd"
        local loop_dev=$(losetup -f --show "$disk_file")
        
        if [ -z "$loop_dev" ]; then
            print_error "Failed to create loop device for $disk_file"
            cleanup_devices
            exit 1
        fi
        
        LOOP_DEVICES+=("$loop_dev")
        print_info "  $disk_file → $loop_dev"
    done
    
    print_success "Loop devices ready: ${LOOP_DEVICES[*]}"
}

# Create RAID array with mdadm
create_raid_array_mdadm() {
    print_info "Creating RAID $RAID_LEVEL array with mdadm..."
    
    MD_DEVICE="/dev/md0"
    for i in {0..127}; do
        if [ ! -b "/dev/md$i" ]; then
            MD_DEVICE="/dev/md$i"
            break
        fi
    done
    
    print_info "Using MD device: $MD_DEVICE"
    
    local mdadm_cmd="mdadm --create $MD_DEVICE --verbose"
    mdadm_cmd="$mdadm_cmd --level=$RAID_LEVEL"
    mdadm_cmd="$mdadm_cmd --raid-devices=$NUM_DISKS"
    mdadm_cmd="$mdadm_cmd --metadata=$METADATA_VERSION"
    
    if [ "$RAID_LEVEL" != "1" ]; then
        mdadm_cmd="$mdadm_cmd --chunk=${STRIPE_SIZE_KB}"
    fi
    
    if [ "$RAID_LEVEL" = "5" ] || [ "$RAID_LEVEL" = "6" ] || [ "$RAID_LEVEL" = "10" ]; then
        mdadm_cmd="$mdadm_cmd --layout=$CHUNK_LAYOUT"
    fi
    
    if [ "$SPARE_DISKS" -gt 0 ]; then
        mdadm_cmd="$mdadm_cmd --spare-devices=$SPARE_DISKS"
    fi
    
    for loop_dev in "${LOOP_DEVICES[@]}"; do
        mdadm_cmd="$mdadm_cmd $loop_dev"
    done
    
    mdadm_cmd="$mdadm_cmd --force --assume-clean"
    
    print_info "Command: $mdadm_cmd"
    echo ""
    
    if ! eval "$mdadm_cmd"; then
        print_error "Failed to create RAID array"
        cleanup_devices
        exit 1
    fi
    
    sleep 2
    
    if [ ! -b "$MD_DEVICE" ]; then
        print_error "RAID device $MD_DEVICE not created"
        cleanup_devices
        exit 1
    fi
    
    print_success "RAID array created: $MD_DEVICE"
    
    echo ""
    mdadm --detail "$MD_DEVICE" | grep -E "Level|Raid Devices|Total Devices|State|Chunk Size|Layout"
    echo ""
}

# Copy data to mdadm RAID
copy_data_to_raid() {
    if [ "$COPY_METHOD" = "block" ]; then
        print_info "Copying data using block-level method (dd)..."
        
        if command -v pv >/dev/null 2>&1; then
            pv "$INPUT_IMAGE" | dd of="$MD_DEVICE" bs=4M conv=noerror,sync status=none
        else
            dd if="$INPUT_IMAGE" of="$MD_DEVICE" bs=4M conv=noerror,sync status=progress
        fi
        
        sync
        print_success "Block-level copy complete"
    else
        print_info "Filesystem copy not yet implemented in universal script"
    fi
}

# Cleanup devices
cleanup_devices() {
    echo ""
    print_info "Cleaning up..."
    
    if [ "$PRESERVE_ARRAY" = "false" ] && [ -n "$MD_DEVICE" ] && [ -b "$MD_DEVICE" ]; then
        print_info "Stopping RAID array: $MD_DEVICE"
        mdadm --stop "$MD_DEVICE" 2>/dev/null || true
        sleep 1
        
        for loop_dev in "${LOOP_DEVICES[@]}"; do
            if [ -b "$loop_dev" ]; then
                mdadm --zero-superblock "$loop_dev" 2>/dev/null || true
            fi
        done
    fi
    
    if [ "$PRESERVE_ARRAY" = "false" ] && [ ${#LOOP_DEVICES[@]} -gt 0 ]; then
        print_info "Detaching loop devices"
        for loop_dev in "${LOOP_DEVICES[@]}"; do
            if [ -b "$loop_dev" ]; then
                losetup -d "$loop_dev" 2>/dev/null || true
            fi
        done
    fi
}

# Show summary
show_summary() {
    echo ""
    echo "=========================================="
    echo "  RAID Array Creation Complete!"
    echo "=========================================="
    echo ""
    echo "Implementation:    $IMPLEMENTATION_MODE"
    echo "Source Image:      $INPUT_IMAGE"
    echo "RAID Level:        RAID $RAID_LEVEL"
    echo "Number of Disks:   $NUM_DISKS"
    
    if [ "$RAID_LEVEL" != "1" ]; then
        echo "Stripe Size:       ${STRIPE_SIZE_KB} KB"
        if [ "$IMPLEMENTATION_MODE" = "manual" ]; then
            echo "Stripe Direction:  $STRIPE_DIRECTION"
            echo "Stripe Algorithm:  $STRIPE_ALGORITHM"
        fi
    fi
    
    if [ "$RAID_LEVEL" = "5" ] || [ "$RAID_LEVEL" = "6" ]; then
        echo "Parity Layout:     $CHUNK_LAYOUT"
    fi
    
    if [ "$IMPLEMENTATION_MODE" != "manual" ]; then
        echo "Metadata Version:  $METADATA_VERSION"
    fi
    
    echo ""
    echo "Output Disks:"
    for ((disk=0; disk<NUM_DISKS; disk++)); do
        local disk_file="${OUTPUT_PREFIX}_${disk}.dd"
        local size_mb=$(( $(stat -c%s "$disk_file") / 1024 / 1024 ))
        echo "  Disk $disk: $disk_file (${size_mb} MB)"
    done
    
    echo ""
    echo "=========================================="
    echo "  Reassembly Instructions"
    echo "=========================================="
    echo ""
    
    if [ "$IMPLEMENTATION_MODE" = "mdadm" ] || [ "$IMPLEMENTATION_MODE" = "hybrid" ]; then
        if [ "$PRESERVE_ARRAY" = "true" ]; then
            echo "Array is currently active: $MD_DEVICE"
            echo "To stop: sudo mdadm --stop $MD_DEVICE"
        else
            echo "To reassemble:"
            echo "  sudo mdadm --assemble --scan"
            echo "  # or manually:"
            local total_disks=$((NUM_DISKS + SPARE_DISKS))
            for ((i=0; i<total_disks; i++)); do
                echo "  LOOP$i=\$(sudo losetup -f --show ${OUTPUT_PREFIX}_${i}.dd)"
            done
            echo -n "  sudo mdadm --assemble $MD_DEVICE"
            for ((i=0; i<total_disks; i++)); do
                echo -n " \$LOOP$i"
            done
            echo ""
        fi
    else
        echo "Manual mode - no metadata. To use with mdadm:"
        echo "  # Create array with matching parameters"
        echo "  sudo mdadm --create /dev/md0 --level=$RAID_LEVEL \\"
        echo "    --raid-devices=$NUM_DISKS --chunk=${STRIPE_SIZE_KB} \\"
        for ((disk=0; disk<NUM_DISKS; disk++)); do
            echo "    \$(losetup -f --show ${OUTPUT_PREFIX}_${disk}.dd) \\"
        done | sed '$ s/ \\$//'
    fi
    
    echo ""
    echo "Forensic Analysis Tips:"
    echo "  # Examine raw stripe patterns"
    echo "  xxd ${OUTPUT_PREFIX}_0.dd | less"
    echo ""
    echo "  # Compare data distribution"
    echo "  for i in {0..$((NUM_DISKS-1))}; do"
    echo "    echo \"=== Disk \$i ===\""
    echo "    dd if=${OUTPUT_PREFIX}_\${i}.dd bs=${STRIPE_SIZE_KB}k count=1 2>/dev/null | xxd | head -5"
    echo "  done"
    
    if [ "$IMPLEMENTATION_MODE" = "mdadm" ] || [ "$IMPLEMENTATION_MODE" = "hybrid" ]; then
        echo ""
        echo "  # Examine RAID metadata"
        echo "  sudo mdadm --examine ${OUTPUT_PREFIX}_0.dd"
    fi
}

# Ask preserve array
ask_preserve_array() {
    if [ "$IMPLEMENTATION_MODE" != "mdadm" ] && [ "$IMPLEMENTATION_MODE" != "hybrid" ]; then
        PRESERVE_ARRAY=false
        return
    fi
    
    echo ""
    read -p "Keep RAID array assembled after script exits? (y/n, default: n): " preserve
    preserve=${preserve:-n}
    
    if [ "$preserve" = "y" ]; then
        PRESERVE_ARRAY=true
        print_info "RAID array will remain assembled"
        print_warning "Remember to stop the array when done: sudo mdadm --stop $MD_DEVICE"
    else
        PRESERVE_ARRAY=false
        print_info "RAID array will be stopped on exit"
    fi
}

# Main execution
main() {
    show_banner
    check_root
    check_dependencies
    
    get_implementation_mode
    
    # Check if input image was provided as command-line argument
    if [ -n "$1" ]; then
        INPUT_IMAGE="$1"
        
        if [ ! -f "$INPUT_IMAGE" ]; then
            print_error "File not found: $INPUT_IMAGE"
            exit 1
        fi
        
        if [ ! -r "$INPUT_IMAGE" ]; then
            print_error "File not readable: $INPUT_IMAGE"
            exit 1
        fi
        
        local size_bytes=$(stat -c%s "$INPUT_IMAGE" 2>/dev/null || stat -f%z "$INPUT_IMAGE" 2>/dev/null)
        local size_mb=$((size_bytes / 1024 / 1024))
        DISK_SIZE_MB=$size_mb
        
        print_success "Using provided input: $INPUT_IMAGE (${size_mb} MB)"
    else
        get_input_image
    fi
    
    get_output_prefix
    get_raid_level
    get_num_disks
    get_spare_disks
    get_stripe_size
    get_stripe_direction
    get_stripe_algorithm
    get_raid_layout
    get_metadata_version
    get_copy_method
    
    # Show configuration
    echo ""
    echo "=========================================="
    echo "  Configuration Summary"
    echo "=========================================="
    echo "Implementation:    $IMPLEMENTATION_MODE"
    echo "Input Image:       $INPUT_IMAGE"
    echo "Output Prefix:     $OUTPUT_PREFIX"
    echo "RAID Level:        $RAID_LEVEL"
    echo "Number of Disks:   $NUM_DISKS"
    if [ "$SPARE_DISKS" -gt 0 ]; then
        echo "Spare Disks:       $SPARE_DISKS"
    fi
    if [ "$RAID_LEVEL" != "1" ]; then
        echo "Chunk Size:        ${STRIPE_SIZE_KB} KB"
        if [ "$IMPLEMENTATION_MODE" = "manual" ]; then
            echo "Stripe Direction:  $STRIPE_DIRECTION"
            echo "Stripe Algorithm:  $STRIPE_ALGORITHM"
        fi
    fi
    if [ "$RAID_LEVEL" = "5" ] || [ "$RAID_LEVEL" = "6" ] || [ "$RAID_LEVEL" = "10" ]; then
        echo "Layout:            $CHUNK_LAYOUT"
    fi
    if [ "$IMPLEMENTATION_MODE" != "manual" ]; then
        echo "Metadata Version:  $METADATA_VERSION"
        echo "Copy Method:       $COPY_METHOD"
    fi
    echo "Disk Size:         ${DISK_SIZE_MB} MB each"
    echo ""
    
    read -p "Proceed with RAID creation? (y/n, default: y): " confirm
    confirm=${confirm:-y}
    if [ "$confirm" != "y" ]; then
        print_info "Operation cancelled"
        exit 0
    fi
    
    echo ""
    create_disk_images
    
    # Execute based on mode
    if [ "$IMPLEMENTATION_MODE" = "manual" ]; then
        # Manual implementation only
        case $RAID_LEVEL in
            0) create_raid0_manual ;;
            1) create_raid1_manual ;;
            5) create_raid5_manual ;;
            6) create_raid6_manual ;;
            10) create_raid10_manual ;;
        esac
    elif [ "$IMPLEMENTATION_MODE" = "mdadm" ]; then
        # mdadm only
        setup_loop_devices
        create_raid_array_mdadm
        copy_data_to_raid
        ask_preserve_array
        
        if [ "$PRESERVE_ARRAY" = "false" ]; then
            cleanup_devices
        fi
    else
        # Hybrid mode - manual first, then add metadata
        case $RAID_LEVEL in
            0) create_raid0_manual ;;
            1) create_raid1_manual ;;
            5) create_raid5_manual ;;
            6) create_raid6_manual ;;
            10) create_raid10_manual ;;
        esac
        
        print_info "Manual layout complete, now adding mdadm metadata..."
        setup_loop_devices
        
        # Create array on top of existing data
        print_warning "Adding metadata will mark array as 'clean' but data is already there"
        create_raid_array_mdadm
        ask_preserve_array
        
        if [ "$PRESERVE_ARRAY" = "false" ]; then
            cleanup_devices
        fi
    fi
    
    show_summary
    
    print_success "RAID array creation complete!"
}

# Trap cleanup
trap cleanup_devices EXIT

# Run - pass command-line arguments to main
main "$@"
