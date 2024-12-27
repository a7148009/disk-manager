#!/bin/bash

###########################################
# 磁盘挂载管理脚本
# 版本：2.0.0
# 支持的系统：Ubuntu 18.04+, Debian 9+
###########################################

###########################################
# 第一部分：基础配置和初始化
###########################################

# 严格模式
set -e
set -u

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 全局变量
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
LOG_FILE="/var/log/disk_mount.log"
SYSTEM_DISKS=()
DISKS=()
SELECTED_DISK=""
SELECTED_FS=""
SMARTCTL_AVAILABLE=false

# 显示欢迎信息
show_welcome() {
    echo -e "\n${BLUE}=== 磁盘挂载管理工具 v2.0 ===${NC}"
    echo "作者：入戏太深"
    echo "支持系统：Ubuntu 18.04+, Debian 9+"
    echo -e "更新日期：2024-03-20\n"
}

# 检查系统兼容性
check_system_compatibility() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}错误：无法检测系统版本${NC}"
        exit 1
    fi
    
    . /etc/os-release
    
    case $ID in
        ubuntu)
            if [ "${VERSION_ID%%.*}" -lt 18 ]; then
                echo -e "${RED}错误：不支持的 Ubuntu 版本${NC}"
                echo -e "${YELLOW}本脚本仅支持 Ubuntu 18.04 及以上版本${NC}"
                exit 1
            fi
            ;;
        debian)
            if [ "${VERSION_ID%%.*}" -lt 9 ]; then
                echo -e "${RED}错误：不支持的 Debian 版本${NC}"
                echo -e "${YELLOW}本脚本仅支持 Debian 9 及以上版本${NC}"
                exit 1
            fi
            ;;
        *)
            echo -e "${RED}错误：不支持的系统类型${NC}"
            echo -e "${YELLOW}本脚本仅支持 Ubuntu 18.04+ 和 Debian 9+ 系统${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}系统检查通过: $PRETTY_NAME${NC}"
}

# 检查root权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：此脚本需要root权限运行${NC}"
        echo "请使用 sudo 或 root 用户运行"
        exit 1
    fi
}

# 初始化日志
init_logging() {
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - 磁盘挂载脚本启动" >> "$LOG_FILE"
}

# 错误处理
handle_error() {
    local error_msg="$1"
    echo -e "${RED}错误: $error_msg${NC}" >&2
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $error_msg" >> "$LOG_FILE"
}

# 检查并安装依赖
check_and_install_dependencies() {
    local pkg_list=(
        "parted"
        "psmisc"
        "util-linux"
        "ntfs-3g"
        "exfatprogs"
        "xfsprogs"
        "smartmontools"
    )
    
    echo -e "${BLUE}正在检查系统依赖...${NC}"
    local missing_pkgs=()
    
    # 检查每个包是否已安装
    for pkg in "${pkg_list[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    # 如果有缺失的包，询问是否安装
    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        echo -e "${YELLOW}以下软件包未安装：${NC}"
        printf '%s\n' "${missing_pkgs[@]}"
        
        echo -e "${YELLOW}是否要自动安装这些软件包？[Y/n]${NC}"
        read -p "> " choice
        
        case $choice in
            [Nn]*)
                echo -e "${RED}缺少必要的软件包，脚本可能无法正常工作${NC}"
                return 1
                ;;
            *)
                echo -e "${BLUE}正在更新软件包列表...${NC}"
                if ! apt-get update; then
                    echo -e "${RED}更新软件包列表失败${NC}"
                    return 1
                fi
                
                echo -e "${BLUE}正在安装缺失的软件包...${NC}"
                if ! apt-get install -y "${missing_pkgs[@]}"; then
                    echo -e "${RED}软件包安装失败${NC}"
                    return 1
                fi
                echo -e "${GREEN}软件包安装完成${NC}"
                ;;
        esac
    else
        echo -e "${GREEN}所有必要的软件包已安装${NC}"
    fi
    
    return 0
}

###########################################
# 第二部分：文件系统管理
###########################################

# 检查系统命令
check_system_commands() {
    local required_commands=(
        "parted"
        "lsblk"
        "blkid"
        "mount"
        "umount"
        "mkfs.ext4"
        "mkfs.ntfs"
        "mkfs.vfat"
        "mkfs.xfs"
        "mkfs.exfat"
        "lsof"
        "fuser"
    )
    
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        echo -e "${RED}错误: 以下必要命令缺失:${NC}"
        printf '%s\n' "${missing_commands[@]}"
        return 1
    fi
    
    return 0
}

# 文件系统配置
declare -A FS_DESCRIPTIONS
declare -A FS_COMMANDS
declare -A FS_MOUNT_OPTIONS

# 初始化文件系统配置
init_fs_configs() {
    # 文件系统描述
    FS_DESCRIPTIONS=(
        ["ext4"]="Linux默认文件系统，支持日志功能，稳定可靠"
        ["ntfs"]="Windows兼容，支持大文件和权限管理"
        ["fat32"]="通用兼容，单文件最大4GB，适合移动设备"
        ["xfs"]="适合大文件存储，支持快照功能"
        ["exfat"]="跨平台兼容，支持大文件，适合外部存储"
    )
    
    # 格式化命令
    FS_COMMANDS=(
        ["ext4"]="mkfs.ext4 -F"
        ["ntfs"]="mkfs.ntfs -f"
        ["fat32"]="mkfs.vfat -F 32"
        ["xfs"]="mkfs.xfs -f"
        ["exfat"]="mkfs.exfat"
    )
    
    # 挂载选项
    FS_MOUNT_OPTIONS=(
        ["ext4"]="-o defaults"
        ["ntfs"]="-t ntfs-3g -o defaults,uid=$(id -u),gid=$(id -g),umask=0022"
        ["ntfs-3g"]="-t ntfs-3g -o defaults,uid=$(id -u),gid=$(id -g),umask=0022"
        ["fat32"]="-o defaults,uid=$(id -u),gid=$(id -g),umask=0022"
        ["vfat"]="-o defaults,uid=$(id -u),gid=$(id -g),umask=0022"
        ["xfs"]="-o defaults"
        ["exfat"]="-o defaults,uid=$(id -u),gid=$(id -g),umask=0022"
    )
}

# 选择文件系统
select_filesystem() {
    echo -e "${YELLOW}请选择文件系统类型：${NC}"
    local i=1
    local fs_types=("ext4" "ntfs" "fat32" "xfs" "exfat")
    
    for fs in "${fs_types[@]}"; do
        echo "$i. $fs  (${FS_DESCRIPTIONS[$fs]})"
        ((i++))
    done
    
    echo "输入 'q' 返回上级菜单"
    
    while true; do
        read -p "> " choice
        case $choice in
            [Qq]*)
                return 1
                ;;
            [1-5])
                SELECTED_FS="${fs_types[$((choice-1))]}"
                return 0
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                ;;
        esac
    done
}

# 验证文件系统
verify_filesystem() {
    local device=$1
    local fs_type=$2
    
    echo -e "${BLUE}正在验证文件系统...${NC}"
    
    case $fs_type in
        ext4)
            e2fsck -f "$device"
            ;;
        ntfs)
            ntfsfix "$device"
            ;;
        fat32)
            fsck.vfat -a "$device"
            ;;
        xfs)
            xfs_repair "$device"
            ;;
        exfat)
            fsck.exfat "$device"
            ;;
        *)
            echo -e "${YELLOW}警告：不支持的文件系统类型${NC}"
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}文件系统验证成功${NC}"
        return 0
    else
        echo -e "${RED}文件系统验证失败${NC}"
        return 1
    fi
}

# 格式化分区
format_partition() {
    local device=$1
    local fs_type=$2
    local format_cmd="${FS_COMMANDS[$fs_type]}"
    
    echo -e "${YELLOW}正在格式化 $device 为 $fs_type 文件系统...${NC}"
    if ! $format_cmd "$device" > /dev/null 2>&1; then
        handle_error "格式化失败"
        return 1
    fi
    
    # 添加文件系统验证
    if ! verify_filesystem "$device" "$fs_type"; then
        echo -e "${RED}警告：文件系统验证失败${NC}"
        return 1
    fi
    
    echo -e "${GREEN}格式化完成${NC}"
    return 0
}

###########################################
# 第三部分：磁盘操作
###########################################

# 检查SMART支持
check_smart_support() {
    if command -v smartctl >/dev/null 2>&1; then
        SMARTCTL_AVAILABLE=true
        echo -e "${GREEN}SMART支持已启用${NC}"
    else
        SMARTCTL_AVAILABLE=false
        echo -e "${YELLOW}SMART支持未启用${NC}"
    fi
}

# 检查磁盘健康状态
check_disk_health() {
    local disk=$1
    
    if [ "$SMARTCTL_AVAILABLE" = true ]; then
        echo -e "\n${BLUE}=== 磁盘健康状态 ===${NC}"
        
        # 检查SMART支持
        if ! smartctl -i "$disk" &>/dev/null; then
            echo -e "${YELLOW}此设备不支持SMART功能${NC}"
            return 0
        fi
        
        # 获取SMART状态
        local health_status=$(smartctl -H "$disk" | grep "SMART overall-health")
        echo -e "健康状态: ${GREEN}$health_status${NC}"
        
        # 显示重要SMART属性
        echo -e "\n${BLUE}重要SMART属性：${NC}"
        smartctl -A "$disk" | grep -E "Raw_Read_Error_Rate|Reallocated_Sector_Ct|Power_On_Hours|Temperature_Celsius|Current_Pending_Sector"
    fi
}

# 获取系统磁盘列表
get_system_disks() {
    SYSTEM_DISKS=()
    
    # 获取根分区所在磁盘
    local root_disk=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /))
    if [ -n "$root_disk" ]; then
        SYSTEM_DISKS+=("$root_disk")
    fi
    
    # 获取其他系统关键目录所在磁盘
    local system_mounts=("/boot" "/home" "/var" "/usr")
    for mount_point in "${system_mounts[@]}"; do
        if mountpoint -q "$mount_point"; then
            local disk=$(lsblk -no PKNAME $(findmnt -n -o SOURCE "$mount_point"))
            if [ -n "$disk" ] && [[ ! " ${SYSTEM_DISKS[@]} " =~ " ${disk} " ]]; then
                SYSTEM_DISKS+=("$disk")
            fi
        fi
    done
}

# 获取可用磁盘列表
get_available_disks() {
    DISKS=()
    # 获取系统磁盘列表
    get_system_disks
    
    # 获取所有磁盘信息
    local all_disks=$(lsblk -dpno NAME,SIZE | grep -E '^/dev/(sd[a-z]|vd[a-z]|nvme[0-9]n[0-9])' || true)
    
    if [ -z "$all_disks" ]; then
        echo -e "${YELLOW}未找到可用磁盘${NC}"
        return 1
    fi
    
    while read -r disk size; do
        local is_system=0
        for sys_disk in "${SYSTEM_DISKS[@]}"; do
            if [[ "$(basename $disk)" == "$sys_disk" ]]; then
                is_system=1
                break
            fi
        done
        
        # 检查磁盘是否被锁定或正在使用
        local is_busy=0
        if lsof "$disk"* >/dev/null 2>&1 || fuser -m "$disk"* >/dev/null 2>&1; then
            is_busy=1
        fi
        
        DISKS+=("$disk $size $is_system $is_busy")
    done <<< "$all_disks"
    
    return 0
}

# 显示磁盘列表
show_disk_list() {
    echo -e "\n${GREEN}可用磁盘列表：${NC}"
    printf "%-6s %-12s %-10s %-15s %-12s %-10s %-10s\n" \
           "序号" "设备名" "大小" "型号" "文件系统" "分区情况" "状态"
    echo "--------------------------------------------------------------------------------"
    
    local i=1
    for disk_info in "${DISKS[@]}"; do
        local disk_name=$(echo "$disk_info" | awk '{print $1}')
        local disk_size=$(echo "$disk_info" | awk '{print $2}')
        local is_system_disk=$(echo "$disk_info" | awk '{print $3}')
        local is_busy=$(echo "$disk_info" | awk '{print $4}')
        
        # 获取实时信息
        local disk_model=$(lsblk -dno MODEL "$disk_name" 2>/dev/null || echo "N/A")
        local fs_type
        local partition_count=0
        local mount_points
        local partition_status
        local disk_status
        
        # 检查是否有分区
        if [ -b "${disk_name}1" ]; then
            fs_type=$(blkid -o value -s TYPE "${disk_name}1" 2>/dev/null || echo "未格式化")
            partition_count=$(lsblk -no NAME "$disk_name" | grep -v "$(basename $disk_name)$" | wc -l)
        else
            fs_type=$(blkid -o value -s TYPE "$disk_name" 2>/dev/null || echo "未格式化")
        fi
        
        # 获取挂载点信息
        mount_points=$(lsblk -no MOUNTPOINT "$disk_name" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
        
        if [ "$partition_count" -eq 0 ]; then
            partition_status="无分区"
        else
            partition_status="$partition_count 个分区"
        fi
        
        if [ "$is_busy" -eq 1 ]; then
            disk_status="使用中"
        elif [ -n "$mount_points" ]; then
            disk_status="已挂载"
        else
            disk_status="未挂载"
        fi
        
        # 使用不同颜色显示系统磁盘和普通磁盘
        if [ "$is_system_disk" -eq 1 ]; then
            printf "${YELLOW}%-6s %-12s %-10s %-15s %-12s %-10s %-10s${NC}\n" \
                   "$i" "$(basename $disk_name)" "$disk_size" \
                   "${disk_model:0:15}" "$fs_type" "$partition_status" "$disk_status"
        else
            printf "%-6s %-12s %-10s %-15s %-12s %-10s %-10s\n" \
                   "$i" "$(basename $disk_name)" "$disk_size" \
                   "${disk_model:0:15}" "$fs_type" "$partition_status" "$disk_status"
        fi
        
        # 显示挂载点信息
        if [ -n "$mount_points" ]; then
            echo -e "${BLUE}   └─ 挂载点: $mount_points${NC}"
        fi
        
        ((i++))
    done
    echo
}

###########################################
# 第四部分：分区和挂载管理
###########################################

# 获取磁盘的第一个分区
get_first_partition() {
    local disk=$1
    local first_part
    
    # 尝试获取第一个分区
    first_part=$(lsblk -nplo NAME "$disk" | grep -v "^$disk$" | head -n1)
    
    if [ -n "$first_part" ]; then
        echo "$first_part"
    else
        # 如果没有分区，返回原始设备
        echo "$disk"
    fi
}

# 创建分区
create_partition() {
    local disk=$1
    local mode=$2  # "auto" 或 "manual"
    
    # 首先进行准备工作
    if ! prepare_disk "$disk"; then
        return 1
    fi
    
    echo -e "${BLUE}正在初始化分区表...${NC}"
    
    # 强制卸载所有分区
    for part in $(lsblk -nplo NAME "$disk" | grep -v "^$disk$"); do
        umount -f "$part" 2>/dev/null || true
    done
    
    # 删除所有分区信息
    dd if=/dev/zero of="$disk" bs=512 count=1 conv=notrunc 2>/dev/null
    sync
    sleep 2
    
    # 创建 GPT 分区表
    if ! parted -s "$disk" mklabel gpt; then
        echo -e "${RED}创建分区表失败${NC}"
        return 1
    fi
    
    # 确保分区表已经写入
    sync
    sleep 2
    
    if [ "$mode" = "auto" ]; then
        echo -e "${BLUE}正在创建单个分区（使用全部空间）...${NC}"
        if ! parted -s "$disk" mkpart primary 0% 100%; then
            echo -e "${RED}创建分区失败${NC}"
            return 1
        fi
        
        # 强制内核重新读取分区表
        echo -e "${YELLOW}正在更新分区表...${NC}"
        sync
        sleep 2
        partprobe "$disk" 2>/dev/null || true
        
        # 等待udev处理完成
        udevadm settle
        
        # 多次检查分区是否存在
        local max_attempts=10
        local attempt=1
        local partition="${disk}1"
        
        echo -e "${YELLOW}等待系统识别新分区...${NC}"
        while [ $attempt -le $max_attempts ]; do
            if [ -b "$partition" ]; then
                echo -e "${GREEN}分区 $partition 已创建${NC}"
                return 0
            fi
            echo -n "."
            sleep 1
            ((attempt++))
        done
        
        echo -e "\n${RED}分区创建失败：系统无法识别新分区${NC}"
        return 1
    else
        # 显示可用空间
        echo -e "\n${BLUE}磁盘信息：${NC}"
        parted -s "$disk" print
        
        local total_size=$(parted -s "$disk" print | grep "Disk /dev" | cut -d: -f2 | sed 's/B//' | tr -d ' ')
        echo -e "\n${YELLOW}可用空间: $total_size${NC}"
        
        # 获取分区数量
        echo -e "\n${YELLOW}请输入要创建的分区数量 (1-4):${NC}"
        read -p "> " part_count
        
        if ! [[ "$part_count" =~ ^[1-4]$ ]]; then
            echo -e "${RED}无效的分区数量${NC}"
            return 1
        fi
        
        local start=0
        for ((i=1; i<=part_count; i++)); do
            echo -e "\n${YELLOW}分区 $i${NC}"
            echo -e "请输入分区大小 (例如: 10GB, 50%, 剩余空间请输入 'max'):"
            read -p "> " size
            
            local end
            if [ "$size" = "max" ] || [ "$i" = "$part_count" ]; then
                end="100%"
            elif [[ "$size" =~ ^[0-9]+%$ ]]; then
                end="$size"
            elif [[ "$size" =~ ^[0-9]+[GT]B$ ]]; then
                end="$size"
            else
                echo -e "${RED}无效的分区大小格式${NC}"
                return 1
            fi
            
            echo -e "${BLUE}创建分区 $i: $start -> $end${NC}"
            if ! parted -s "$disk" mkpart primary "$start" "$end"; then
                echo -e "${RED}创建分区 $i 失败${NC}"
                return 1
            fi
            
            start="$end"
        done
        
        # 更新分区表
        sync
        sleep 2
        partprobe "$disk" 2>/dev/null || true
        udevadm settle
        
        return 0
    fi
}

# 准备磁盘
prepare_disk() {
    local disk=$1
    
    echo -e "${BLUE}检查磁盘使用状态...${NC}"
    
    # 检查是否有进程在使用磁盘
    local busy_procs=$(lsof "$disk"* 2>/dev/null)
    if [ -n "$busy_procs" ]; then
        echo -e "${RED}错误：磁盘正在被以下进程使用：${NC}"
        echo "$busy_procs"
        echo -e "${YELLOW}是否要强制结束这些进程？[y/N]${NC}"
        read -p "> " choice
        case $choice in
            [Yy]*)
                echo -e "${BLUE}正在结束进程...${NC}"
                fuser -k -9 "$disk"* 2>/dev/null || true
                sleep 2
                ;;
            *)
                echo -e "${YELLOW}操作已取消${NC}"
                return 1
                ;;
        esac
    fi
    
    # 检查并卸载所有相关的挂载点
    if ! unmount_all_partitions "$disk"; then
        return 1
    fi
    
    # 等待系统完成所有IO操作
    sync
    sleep 2
    
    return 0
}

###########################################
# 第五部分：挂载管理和用户界面
###########################################

# 获取默认挂载点
get_default_mount_point() {
    local device=$1
    local device_name=$(basename "$device")
    echo "/mnt/$device_name"
}

# 挂载磁盘
mount_disk() {
    local disk=$1
    local mount_point=$2
    local fs_type=$3
    
    # 检查文件系统类型
    local target_device
    if lsblk -no TYPE "$disk" | grep -q "disk"; then
        target_device=$(get_first_partition "$disk")
        [ "$target_device" != "$disk" ] && disk="$target_device"
    fi
    
    # 检查设备是否已经挂载或被使用
    if mountpoint -q "$mount_point" || grep -q "^$disk " /proc/mounts || fuser -m "$disk" >/dev/null 2>&1; then
        echo -e "${YELLOW}警告：设备已经挂载或正在被使用${NC}"
        echo -e "当前挂载点: $(findmnt -n -o TARGET "$disk" 2>/dev/null)"
        
        # 显示正在使用设备的进程
        echo -e "\n${BLUE}正在使用此设备的进程：${NC}"
        fuser -mv "$disk" 2>/dev/null || echo "没有找到使用此设备的进程"
        
        echo -e "\n${YELLOW}是否要强制卸载并重新挂载？[y/N]${NC}"
        read -p "> " choice
        case $choice in
            [Yy]*)
                echo -e "${BLUE}正在终止使用此设备的进程...${NC}"
                fuser -mk "$disk" 2>/dev/null || true
                sleep 2
                
                echo -e "${BLUE}正在卸载...${NC}"
                if ! umount -f "$disk" 2>/dev/null; then
                    echo -e "${RED}卸载失败，尝试使用 ntfs-3g 强制卸载...${NC}"
                    if ! ntfs-3g -o remove_hiberfile,force "$disk" "$mount_point" 2>/dev/null; then
                        echo -e "${RED}强制卸载失败${NC}"
                        return 1
                    fi
                fi
                ;;
            *)
                echo -e "${YELLOW}操作已取消${NC}"
                return 1
                ;;
        esac
    fi
    
    # 创建挂载点
    if [ ! -d "$mount_point" ]; then
        echo -e "${BLUE}创建挂载点 $mount_point${NC}"
        if ! mkdir -p "$mount_point"; then
            handle_error "创建挂载点失败"
            return 1
        fi
    fi
    
    # 执行挂载
    echo -e "${BLUE}正在挂载 $disk 到 $mount_point${NC}"
    
    # 获取挂载选项
    local mount_opts="${FS_MOUNT_OPTIONS[$fs_type]:-"-o defaults"}"
    
    if ! mount $mount_opts "$disk" "$mount_point" 2>&1; then
        echo -e "${RED}常规挂载失败，尝试使用 ntfs-3g 特殊选项...${NC}"
        if [ "$fs_type" = "ntfs" ] || [ "$fs_type" = "ntfs-3g" ]; then
            if ! ntfs-3g -o remove_hiberfile,force "$disk" "$mount_point" 2>/dev/null; then
                handle_error "挂载失败"
                return 1
            fi
        else
            handle_error "挂载失败"
            return 1
        fi
    fi
    
    # 重新加载 systemd
    if command -v systemctl >/dev/null 2>&1; then
        echo -e "${BLUE}正在重新加载 systemd...${NC}"
        systemctl daemon-reload
    fi
    
    echo -e "${GREEN}挂载完成${NC}"
    
    # 询问是否添加到fstab
    echo -e "\n${YELLOW}是否要将此挂载点添加到fstab？[y/N]${NC}"
    read -p "> " choice
    case $choice in
        [Yy]*)
            if add_to_fstab "$disk" "$mount_point" "$fs_type"; then
                echo -e "${GREEN}已添加到fstab${NC}"
                # 再次重新加载 systemd
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl daemon-reload
                fi
            else
                echo -e "${RED}添加到fstab失败${NC}"
            fi
            ;;
    esac
}

# 添加到fstab
add_to_fstab() {
    local device=$1
    local mount_point=$2
    local fs_type=$3
    
    # 检查参数
    if [ -z "$device" ] || [ -z "$mount_point" ] || [ -z "$fs_type" ]; then
        echo -e "${RED}错误：缺少必要参数${NC}"
        return 1
    fi
    
    # 检查设备是否存在
    if [ ! -b "$device" ]; then
        echo -e "${RED}错误：设备 $device 不存在${NC}"
        return 1
    fi
    
    # 检查挂载点是否存在
    if [ ! -d "$mount_point" ]; then
        echo -e "${RED}错误：挂载点 $mount_point 不存在${NC}"
        return 1
    fi
    
    # 获取设备的UUID
    local uuid=$(blkid -s UUID -o value "$device")
    if [ -z "$uuid" ]; then
        echo -e "${RED}错误：无法获取设备UUID${NC}"
        return 1
    fi
    
    echo -e "${BLUE}设备信息：${NC}"
    echo "设备: $device"
    echo "UUID: $uuid"
    echo "挂载点: $mount_point"
    echo "文件系统: $fs_type"
    
    # 检查是否已经存在于fstab中
    if grep -q "UUID=$uuid" /etc/fstab; then
        echo -e "${YELLOW}此设备已存在于fstab中${NC}"
        return 0
    fi
    
    # 备份fstab
    cp /etc/fstab /etc/fstab.backup
    
    # 构建挂载选项
    local mount_options
    case $fs_type in
        ext4)
            mount_options="defaults"
            ;;
        ntfs|ntfs-3g)
            fs_type="ntfs-3g"
            mount_options="defaults,nofail,uid=$(id -u),gid=$(id -g),umask=0022"
            ;;
        fat32|vfat)
            fs_type="vfat"
            mount_options="defaults,nofail,iocharset=utf8,rw,uid=$(id -u),gid=$(id -g),umask=0022"
            ;;
        xfs)
            mount_options="defaults"
            ;;
        exfat)
            mount_options="defaults,nofail,uid=$(id -u),gid=$(id -g),umask=0022"
            ;;
        *)
            echo -e "${RED}错误：不支持的文件系统类型 $fs_type${NC}"
            return 1
            ;;
    esac
    
    # 构建fstab条目
    local fstab_entry="UUID=$uuid $mount_point $fs_type $mount_options 0 0"
    echo -e "${BLUE}准备添加以下条目到fstab：${NC}"
    echo "$fstab_entry"
    
    # 先卸载当前挂载点
    echo -e "${BLUE}正在卸载当前挂载点以进行测试...${NC}"
    if mountpoint -q "$mount_point"; then
        if ! umount -f "$mount_point" 2>/dev/null; then
            if [ "$fs_type" = "ntfs-3g" ]; then
                echo -e "${YELLOW}尝试使用 ntfs-3g 强制卸载...${NC}"
                ntfs-3g -o remove_hiberfile,force "$device" "$mount_point" 2>/dev/null || true
                sleep 1
                umount -f "$mount_point" 2>/dev/null || true
            fi
        fi
    fi
    
    # 添加新的挂载项
    echo -e "\n# 由磁盘挂载工具添加于 $(date '+%Y-%m-%d %H:%M:%S')" >> /etc/fstab
    echo "$fstab_entry" >> /etc/fstab
    
    # 测试挂载
    echo -e "${BLUE}正在测试新的挂载点...${NC}"
    if ! mount "$mount_point" 2>/dev/null; then
        # 如果直接挂载失败，尝试使用完整的挂载命令
        if ! mount -t "$fs_type" -o "$mount_options" "$device" "$mount_point" 2>/dev/null; then
            echo -e "${RED}错误：挂载测试失败，正在还原备份${NC}"
            mv /etc/fstab.backup /etc/fstab
            return 1
        fi
    fi
    
    # 验证挂载是否成功
    if ! mountpoint -q "$mount_point"; then
        echo -e "${RED}错误：挂载点验证失败${NC}"
        mv /etc/fstab.backup /etc/fstab
        return 1
    fi
    
    echo -e "${GREEN}成功添加到fstab${NC}"
    return 0
}

# 卸载所有分区
unmount_all_partitions() {
    local disk=$1
    local partitions
    
    # 获取所有分区
    partitions=$(lsblk -nplo NAME "$disk" | grep -v "^$disk$")
    
    if [ -n "$partitions" ]; then
        echo -e "${BLUE}正在卸载所有分区...${NC}"
        for part in $partitions; do
            if mountpoint -q "$part" || grep -q "^$part " /proc/mounts; then
                echo -e "${YELLOW}卸载 $part${NC}"
                if ! umount -f "$part" 2>/dev/null; then
                    echo -e "${RED}卸载 $part 失败${NC}"
                    return 1
                fi
            fi
        done
    fi
    
    return 0
}

###########################################
# 第六部分：主程序和菜单
###########################################

# 显示主菜单
show_main_menu() {
    echo -e "\n${BLUE}=== 主菜单 ===${NC}"
    echo "0. 退出程序"
    echo "1. 格式化磁盘"
    echo "2. 挂载磁盘"
    echo "3. 卸载磁盘"
    echo "4. 查看磁盘详情"
    echo "5. 刷新磁盘列表"
    echo -e "${YELLOW}请选择操作 (0-5):${NC}"
}

# 格式化磁盘
format_disk() {
    local disk=$1
    local fs_type=$2
    
    # 显示目标磁盘信息
    echo -e "\n目标磁盘信息："
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$disk"
    
    echo -e "\n${RED}警告：即将格式化 $disk${NC}"
    echo "此操作将删除磁盘上的所有数据！"
    echo -e "${YELLOW}请输入磁盘名称 $(basename $disk) 以确认操作：${NC}"
    read -p "> " confirm
    
    if [ "$confirm" != "$(basename $disk)" ]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return 1
    fi
    
    # 卸载所有分区
    unmount_all_partitions "$disk"
    
    # 询问是否需要创建分区
    echo -e "\n是否要创建分区？"
    echo "1. 是，创建单个分区（使用全部空间）"
    echo "2. 是，手动创建多个分区"
    echo "3. 否，直接格式化整个磁盘"
    read -p "> " choice
    
    case $choice in
        1)
            echo -e "${BLUE}正在准备创建分区...${NC}"
            if ! create_partition "$disk" "auto"; then
                echo -e "${RED}分区创建失败${NC}"
                return 1
            fi
            # 格式化第一个分区
            format_partition "${disk}1" "$fs_type"
            ;;
        2)
            if ! create_partition "$disk" "manual"; then
                echo -e "${RED}分区创建失败${NC}"
                return 1
            fi
            # 格式化所有创建的分区
            for part in $(lsblk -nplo NAME "$disk" | grep -v "^$disk$"); do
                format_partition "$part" "$fs_type"
            done
            ;;
        3)
            format_partition "$disk" "$fs_type"
            ;;
        *)
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac
}

# 显示磁盘详情
show_disk_details() {
    local disk=$1
    
    echo -e "\n${BLUE}=== 磁盘详细信息 ===${NC}"
    
    echo -e "${GREEN}基本信息：${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$disk"
    
    echo -e "\n${GREEN}分区信息：${NC}"
    parted -s "$disk" print 2>/dev/null || echo "无法读取分区表"
    
    echo -e "\n${GREEN}文件系统信息：${NC}"
    blkid "$disk"* 2>/dev/null || echo "无法读取文件系统信息"
    
    echo -e "\n${GREEN}使用情况：${NC}"
    df -h "$disk"* 2>/dev/null || echo "无法获取使用情况"
    
    echo -e "\n${GREEN}进程使用情况：${NC}"
    lsof "$disk"* 2>/dev/null || echo "当前没有进程使用此设备"
    
    # 检查磁盘健康状态
    check_disk_health "$disk"
}

# 初始化函数
initialize() {
    # 显示欢迎信息
    show_welcome
    
    # 检查系统兼容性
    check_system_compatibility
    
    # 检查 root 权限
    check_root
    
    # 初始化日志
    init_logging
    
    # 检查并安装依赖
    if ! check_and_install_dependencies; then
        echo -e "${RED}初始化失败：缺少必要的依赖${NC}"
        exit 1
    fi
    
    # 检查系统命令
    check_system_commands
    
    # 初始化文件系统配置
    init_fs_configs
    
    # 检查SMART支持
    check_smart_support
    
    # 清屏并显示主界面
    clear
}

# 主程序
main() {
    # 初始化
    initialize
    
    # 主循环
    while true; do
        # 获取并显示磁盘列表
        if ! get_available_disks; then
            echo -e "${RED}无可用磁盘${NC}"
            exit 1
        fi
        show_disk_list
        
        # 显示主菜单
        show_main_menu
        read -p "> " choice
        
        case $choice in
            0)  # 退出
                echo -e "${GREEN}感谢使用！${NC}"
                exit 0
                ;;
            1)  # 格式化磁盘
                if select_disk; then
                    if select_filesystem; then
                        format_disk "$SELECTED_DISK" "$SELECTED_FS"
                    fi
                fi
                ;;
            2)  # 挂载磁盘
                if select_disk; then
                    # 获取默认挂载点
                    local default_mount_point=$(get_default_mount_point "$SELECTED_DISK")
                    
                    # 询问挂载点
                    echo -e "${YELLOW}请输入挂载点 [默认: $default_mount_point]${NC}"
                    echo "直接按回车使用默认挂载点"
                    read -p "> " mount_point
                    
                    # 如果用户直接按回车，使用默认挂载点
                    if [ -z "$mount_point" ]; then
                        mount_point="$default_mount_point"
                        echo -e "使用默认挂载点: $mount_point"
                    fi
                    
                    # 检查文件系统类型
                    local target_device
                    if lsblk -no TYPE "$SELECTED_DISK" | grep -q "disk"; then
                        target_device=$(get_first_partition "$SELECTED_DISK")
                        [ "$target_device" != "$SELECTED_DISK" ] && SELECTED_DISK="$target_device"
                    fi
                    
                    fs_type=$(blkid -o value -s TYPE "$SELECTED_DISK")
                    if [ -n "$fs_type" ]; then
                        mount_disk "$SELECTED_DISK" "$mount_point" "$fs_type"
                    else
                        echo -e "${RED}错误：无法检测文件系统类型${NC}"
                    fi
                fi
                ;;
            3)  # 卸载磁盘
                if select_disk; then
                    unmount_all_partitions "$SELECTED_DISK"
                fi
                ;;
            4)  # 查看磁盘详情
                if select_disk; then
                    show_disk_details "$SELECTED_DISK"
                fi
                ;;
            5)  # 刷新磁盘列表
                echo -e "${BLUE}正在刷新磁盘列表...${NC}"
                continue
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                ;;
        esac
        
        echo -e "\n${YELLOW}按回车键继续...${NC}"
        read
        clear
    done
}

# 清理函数
cleanup() {
    echo -e "\n${BLUE}正在清理...${NC}"
    exit 0
}

# 设置信号处理
trap cleanup SIGINT SIGTERM

# 选择磁盘
select_disk() {
    while true; do
        echo -e "${YELLOW}请选择要处理的磁盘序号 (1-${#DISKS[@]})${NC}"
        echo -e "输入 'r' 刷新列表，'q' 返回上级菜单"
        read -p "> " choice
        
        case $choice in
            [Qq]*)
                return 1
                ;;
            [Rr]*)
                get_available_disks && show_disk_list
                continue
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DISKS[@]}" ]; then
                    local disk_info="${DISKS[$((choice-1))]}"
                    SELECTED_DISK=$(echo "$disk_info" | awk '{print $1}')
                    local is_system=$(echo "$disk_info" | awk '{print $3}')
                    local is_busy=$(echo "$disk_info" | awk '{print $4}')
                    
                    if [ "$is_busy" -eq 1 ]; then
                        echo -e "${YELLOW}警告：此磁盘正在使用中${NC}"
                        echo -e "${YELLOW}是否要继续操作？[y/N]${NC}"
                        read -p "> " confirm
                        case $confirm in
                            [Yy]*)
                                ;;
                            *)
                                continue
                                ;;
                        esac
                    fi
                    
                    if [ "$is_system" -eq 1 ]; then
                        echo -e "${RED}警告：您选择了系统磁盘，操作可能导致系统无法启动${NC}"
                        echo -e "${YELLOW}是否确定要继续？[y/N]${NC}"
                        read -p "> " confirm
                        case $confirm in
                            [Yy]*)
                                return 0
                                ;;
                            *)
                                continue
                                ;;
                        esac
                    fi
                    return 0
                else
                    echo -e "${RED}无效的选择${NC}"
                fi
                ;;
        esac
    done
}

# 启动主程序
main