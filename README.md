# pseudodisk

A comprehensive toolkit for creating disk images with various filesystems for forensic analysis practice and education.

## Features

- **Multiple Filesystem Support**: NTFS, FAT32, exFAT, ext2/3/4, XFS
- **Partition Schemes**: GPT (modern) and MBR (legacy)
- **Interactive Configuration**: User-friendly prompts for all parameters
- **Automatic Loop Device Management**: Handles mounting and cleanup
- **Forensic-Ready**: Pre-configured for hex editor and forensic tool analysis

## Prerequisites

### Required Packages

```bash
sudo apt-get update
sudo apt-get install -y \
    parted \
    util-linux \
    e2fsprogs \
    dosfstools
```

### Optional (for specific filesystems)

```bash
# For NTFS support
sudo apt-get install ntfs-3g

# For exFAT support
sudo apt-get install exfat-fuse exfat-utils

# For XFS support
sudo apt-get install xfsprogs

# For forensic analysis tools
sudo apt-get install sleuthkit
```

## Usage

### Creating a Disk Image

Run the main script with sudo:

```bash
sudo ./create_forensic_disk.sh
```

The script will interactively prompt you for:

1. **Filename**: Output file name (default: forensic_disk.dd)
2. **Size**: Choose from presets (100MB, 500MB, 1GB, 5GB) or custom
3. **Partition Scheme**: GPT or MBR
4. **Filesystem**: NTFS, FAT32, exFAT, ext2/3/4, XFS
5. **Volume Label**: Custom label for the filesystem
6. **Mount**: Option to mount immediately after creation

### Example Session

```
==========================================
  Forensic Disk Image Creator
==========================================

Enter output filename (default: forensic_disk.dd): ntfsdisk.dd

Disk Size Options:
  1) 100 MB  (small, quick testing)
  2) 500 MB  (medium)
  3) 1 GB    (standard)
  4) 5 GB    (large)
  5) Custom size

Select disk size [1-5]: 2

Partition Scheme:
  1) GPT (GUID Partition Table) - Modern, Windows 10/11 default
  2) MBR (Master Boot Record) - Legacy, compatible with older systems

Select partition scheme [1-2]: 1

Filesystem Type:
  1) NTFS    (Windows default, requires ntfs-3g)
  2) FAT32   (Universal compatibility, 4GB file limit)
  3) exFAT   (Modern, large file support)
  4) ext4    (Linux default)
  5) ext3    (Older Linux)
  6) ext2    (Legacy Linux, no journaling)
  7) XFS     (High-performance Linux)

Select filesystem [1-7]: 1

Enter volume label (default: FORENSIC): EVIDENCE
```

### Cleaning Up

When finished with your analysis, use the cleanup script:

```bash
# Clean up a specific disk image
sudo ./cleanup_forensic_disk.sh
# Enter filename when prompted

# Or clean up all loop devices
sudo ./cleanup_forensic_disk.sh
# Type 'all' when prompted
```

## Forensic Analysis Guide

### Basic Hex Analysis

#### View raw disk structure
```bash
# Using hexdump
hexdump -C ntfsdisk.dd | less

# Using xxd
xxd ntfsdisk.dd | less

# View first 512 bytes (boot sector)
xxd -l 512 ntfsdisk.dd

# View specific offset (e.g., partition table at 0x1BE for MBR)
xxd -s 0x1BE -l 64 ntfsdisk.dd
```

#### GUI Hex Editors
```bash
# Install Bless (GTK hex editor)
sudo apt-get install bless
bless ntfsdisk.dd

# Or install GHex
sudo apt-get install ghex
ghex ntfsdisk.dd

# Or install wxHexEditor (advanced)
sudo apt-get install wxhexeditor
wxhexeditor ntfsdisk.dd
```

### Partition Analysis

```bash
# View partition table
sudo parted ntfsdisk.dd print

# Or using fdisk
sudo fdisk -l ntfsdisk.dd

# For GPT, use gdisk
sudo apt-get install gdisk
sudo gdisk -l ntfsdisk.dd
```

### Using The Sleuth Kit (TSK)

```bash
# Install if not already present
sudo apt-get install sleuthkit

# Display partition layout
mmls ntfsdisk.dd

# Show filesystem details (offset from mmls output)
fsstat -o 2048 ntfsdisk.dd

# List files in filesystem
fls -o 2048 -r ntfsdisk.dd

# Display file content by inode
icat -o 2048 ntfsdisk.dd [inode_number]

# Show deleted files
fls -o 2048 -rd ntfsdisk.dd

# Timeline analysis
fls -o 2048 -m / -r ntfsdisk.dd > timeline.bodyfile
mactime -b timeline.bodyfile
```

### Manual Loop Device Management

If you need more control over the loop device:

```bash
# Attach image to loop device
sudo losetup -f ntfsdisk.dd

# List all loop devices
sudo losetup -l

# Find out which loop device is attached
sudo losetup -j ntfsdisk.dd

# Mount the partition
sudo mkdir -p /mnt/forensic
sudo mount /dev/loop0p1 /mnt/forensic

# When done, unmount
sudo umount /mnt/forensic

# Detach loop device
sudo losetup -d /dev/loop0
```

### Filesystem-Specific Analysis

#### NTFS Analysis

```bash
# View NTFS volume information
sudo apt-get install ntfs-3g
sudo ntfsinfo -m /dev/loop0p1

# Show NTFS file system usage
sudo ntfscluster -f /dev/loop0p1

# Recover deleted files
sudo apt-get install testdisk
sudo testdisk ntfsdisk.dd
```

#### FAT32 Analysis

```bash
# View FAT information
sudo fsck.vfat -n /dev/loop0p1

# Or using sleuthkit
fsstat -o 2048 ntfsdisk.dd
```

#### ext4 Analysis

```bash
# Dump ext4 superblock
sudo dumpe2fs /dev/loop0p1

# Check filesystem
sudo e2fsck -n /dev/loop0p1

# Show inode information
sudo debugfs -R 'stat <inode>' /dev/loop0p1
```

## Key Forensic Structures to Examine

### Master Boot Record (MBR)
- **Location**: First 512 bytes (0x000-0x1FF)
- **Boot Code**: 0x000-0x1BD (446 bytes)
- **Partition Table**: 0x1BE-0x1FD (64 bytes, 4 entries × 16 bytes)
- **Signature**: 0x1FE-0x1FF (0x55AA)

### GUID Partition Table (GPT)
- **Protective MBR**: Sector 0 (0x000-0x1FF)
- **GPT Header**: Sector 1 (0x200-0x3FF)
- **Partition Entries**: Sectors 2-33 (typically)
- **Backup GPT**: Last sectors of disk

### NTFS Boot Sector
- **Jump Instruction**: 0x000-0x002
- **OEM ID**: 0x003-0x00A ("NTFS    ")
- **Bytes Per Sector**: 0x00B-0x00C
- **Sectors Per Cluster**: 0x00D
- **MFT Location**: 0x030-0x037
- **Signature**: 0x1FE-0x1FF (0x55AA)

### FAT32 Boot Sector
- **Jump Instruction**: 0x000-0x002
- **OEM Name**: 0x003-0x00A
- **Bytes Per Sector**: 0x00B-0x00C
- **Sectors Per Cluster**: 0x00D
- **FAT Copies**: 0x010
- **Signature**: 0x1FE-0x1FF (0x55AA)

## Practice Exercises

### Beginner Level

1. **Identify Partition Scheme**
   - Create disks with GPT and MBR
   - Compare the first 512 bytes
   - Identify the signature differences

2. **Find the Filesystem Type**
   - Create disks with different filesystems
   - Examine boot sector signatures
   - Identify OEM strings

3. **Locate Partition Boundaries**
   - Use hexdump to find partition start
   - Verify with `parted` output

### Intermediate Level

4. **File Recovery Practice**
   - Mount filesystem, create files, unmount
   - Delete files from another mount
   - Practice recovering deleted files

5. **Metadata Analysis**
   - Create files with specific timestamps
   - Use TSK to extract timeline data
   - Correlate timestamps with hex data

6. **Slack Space Investigation**
   - Create small files in large clusters
   - Examine slack space for data remnants
   - Understand cluster allocation

### Advanced Level

7. **Steganography Detection**
   - Hide data in slack space
   - Practice identifying hidden data
   - Compare expected vs actual cluster usage

8. **Partition Hiding**
   - Create multiple partitions
   - Modify partition table
   - Practice recovering hidden partitions

9. **Anti-Forensics Techniques**
   - Study timestamp manipulation
   - Examine wiping patterns
   - Analyze file system corruption

## Troubleshooting

### Loop device not found
```bash
# Ensure loop module is loaded
sudo modprobe loop

# Check available loop devices
ls -la /dev/loop*
```

### Permission denied
```bash
# Always use sudo for these operations
sudo ./create_forensic_disk.sh
```

### Partition not showing up
```bash
# Force kernel to re-read partition table
sudo partprobe /dev/loopX

# Or detach and re-attach
sudo losetup -d /dev/loopX
sudo losetup -f ntfsdisk.dd
```

### Cannot unmount - device busy
```bash
# Find what's using it
sudo lsof | grep /mnt/forensic

# Force unmount (use with caution)
sudo umount -l /mnt/forensic
```