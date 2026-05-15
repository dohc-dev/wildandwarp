#!/bin/bash

# ============================================================================
# build-mrpack.sh - Script to generate client and server .mrpack archives
# ============================================================================
# This script reads the Modrinth modpack structure and creates two .mrpack
# files (client and server variants) with configurable exclusions.
#
# Requirements:
#   - bash, zip, jq
#   - build/modrinth.index.json
#   - build/overrides/ (shared configs)
#   - build/client/overrides/ and build/server/overrides/ (variant configs)
#   - build/mods/, build/resourcepacks/, build/shaderpacks/
#
# Configuration:
#   - build-mrpack.toml (optional) for exclude lists per variant
# ============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CONFIG_FILE="${SCRIPT_DIR}/build-mrpack.toml"
BUILDS_OUTPUT_DIR="${SCRIPT_DIR}/builds"
MODRINTH_INDEX="${BUILD_DIR}/modrinth.index.json"
TEMP_BASE="${TMPDIR:-/tmp}"

# ============================================================================
# Utility Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================================
# Phase 0: Check Dependencies & Load Configuration
# ============================================================================

check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing=0
    
    for cmd in zip jq; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Missing required tool: $cmd"
            missing=$((missing + 1))
        fi
    done
    
    if [ $missing -gt 0 ]; then
        log_error "Please install missing tools and try again"
        exit 1
    fi
    
    log_success "All dependencies found"
}

check_build_structure() {
    log_info "Checking build structure..."
    
    if [ ! -f "$MODRINTH_INDEX" ]; then
        log_error "Missing: $MODRINTH_INDEX"
        exit 1
    fi
    
    if [ ! -d "${BUILD_DIR}/overrides" ]; then
        log_error "Missing: ${BUILD_DIR}/overrides"
        exit 1
    fi
    
    log_success "Build structure is valid"
}

# Parse TOML arrays - simple regex-based parser
# Usage: parse_toml_array "config.toml" "section" "key"
# Returns space-separated quoted values
parse_toml_array() {
    local file=$1
    local section=$2
    local key=$3
    
    if [ ! -f "$file" ]; then
        echo ""
        return 0
    fi
    
    # Find section and extract the key value
    # Match: key = ["value1", "value2", ...]
    local result=$(sed -n "/\[$section\]/,/^\[/p" "$file" | grep "^${key}\s*=" | head -1)
    
    if [ -z "$result" ]; then
        echo ""
        return 0
    fi
    
    # Extract array values: ["item1", "item2"] -> item1 item2
    # Remove key = [ and ]
    local array_str=$(echo "$result" | sed 's/^[^=]*=\s*\[//;s/\]\s*$//')
    
    # Remove quotes and split by comma
    echo "$array_str" | sed 's/"//g' | tr ',' '\n' | sed 's/^\s*//;s/\s*$//' | tr '\n' ' '
}

load_config() {
    log_info "Loading configuration..."
    
    # Initialize empty exclude lists
    CLIENT_EXCLUDE=()
    SERVER_EXCLUDE=()
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "Config file not found: $CONFIG_FILE"
        log_info "Using default (no exclusions)"
        return 0
    fi
    
    log_info "Parsing exclusion lists from $CONFIG_FILE"
    
    # Parse client exclusions
    local client_exclude_str=$(parse_toml_array "$CONFIG_FILE" "client" "exclude")
    if [ -n "$client_exclude_str" ]; then
        mapfile -t CLIENT_EXCLUDE < <(echo "$client_exclude_str" | tr ' ' '\n' | grep -v '^$')
        log_info "Client exclusions: ${#CLIENT_EXCLUDE[@]} items"
    fi
    
    # Parse server exclusions
    local server_exclude_str=$(parse_toml_array "$CONFIG_FILE" "server" "exclude")
    if [ -n "$server_exclude_str" ]; then
        mapfile -t SERVER_EXCLUDE < <(echo "$server_exclude_str" | tr ' ' '\n' | grep -v '^$')
        log_info "Server exclusions: ${#SERVER_EXCLUDE[@]} items"
    fi
}

# ============================================================================
# Phase 1: Initialize & Read Manifest
# ============================================================================

read_manifest() {
    log_info "Reading modrinth.index.json..."
    
    # Extract name and versionId using jq
    MODPACK_NAME=$(jq -r '.name' "$MODRINTH_INDEX" 2>/dev/null || echo "modpack")
    VERSION_ID=$(jq -r '.versionId' "$MODRINTH_INDEX" 2>/dev/null || echo "1.0.0")
    
    log_success "Modpack: $MODPACK_NAME"
    log_success "Version: $VERSION_ID"
}

prompt_customization() {
    log_info "Customization prompts..."
    
    # Prompt for version ID
    read -p "Version ID [$VERSION_ID]: " user_version
    if [ -n "$user_version" ]; then
        VERSION_ID="$user_version"
    fi
    
    # Prompt for modpack name
    read -p "Modpack name [$MODPACK_NAME]: " user_name
    if [ -n "$user_name" ]; then
        MODPACK_NAME="$user_name"
    fi
    
    # Build output file names
    CLIENT_MRPACK="${MODPACK_NAME}-${VERSION_ID}-client.mrpack"
    SERVER_MRPACK="${MODPACK_NAME}-${VERSION_ID}-server.mrpack"
    
    log_success "Output files:"
    log_success "  Client: $CLIENT_MRPACK"
    log_success "  Server: $SERVER_MRPACK"
}

# ============================================================================
# Phase 2: Helper functions for file operations
# ============================================================================

copy_overrides() {
    local source_dir=$1
    local dest_dir=$2
    local variant=$3
    
    if [ ! -d "$source_dir" ]; then
        log_warning "Source directory not found: $source_dir (skipping)"
        return 0
    fi
    
    log_info "Copying overrides to $variant: $source_dir"
    cp -r "$source_dir"/* "$dest_dir/" 2>/dev/null || true
}

apply_exclusions() {
    local work_dir=$1
    local variant=$2
    local -n exclude_list=$3
    
    if [ ${#exclude_list[@]} -eq 0 ]; then
        return 0
    fi
    
    log_info "Applying exclusions for $variant (${#exclude_list[@]} items)"
    
    for exclude_pattern in "${exclude_list[@]}"; do
        # Trim whitespace
        exclude_pattern=$(echo "$exclude_pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ -z "$exclude_pattern" ]; then
            continue
        fi
        
        # Check if pattern contains wildcards
        if [[ "$exclude_pattern" == *"*"* ]] || [[ "$exclude_pattern" == *"?"* ]]; then
            # Wildcard pattern - use find with -wholename for path matching
            local found_any=0
            
            while IFS= read -r matched_path; do
                if [ -n "$matched_path" ]; then
                    found_any=1
                    # Get relative path for display
                    local rel_path="${matched_path#$work_dir/}"
                    log_info "  Excluding: $rel_path"
                    rm -rf "$matched_path" 2>/dev/null || true
                fi
            done < <(find "$work_dir" -wholename "*$exclude_pattern" 2>/dev/null)
            
            if [ $found_any -eq 0 ]; then
                log_warning "  Exclude pattern matched nothing: $exclude_pattern"
            fi
        else
            # Exact path match
            local full_path="${work_dir}/${exclude_pattern}"
            if [ -e "$full_path" ]; then
                log_info "  Excluding: $exclude_pattern"
                rm -rf "$full_path" 2>/dev/null || true
            else
                log_warning "  Exclude pattern matched nothing: $exclude_pattern"
            fi
        fi
    done
}

copy_content_dirs() {
    local work_dir=$1
    local variant=$2
    
    # List of content directories to copy if they exist
    local dirs=("mods" "resourcepacks" "shaderpacks")
    
    for dir in "${dirs[@]}"; do
        if [ -d "${BUILD_DIR}/${dir}" ]; then
            log_info "Copying $dir/ to $variant"
            cp -r "${BUILD_DIR}/${dir}" "$work_dir/" 2>/dev/null || true
        fi
    done
}

create_mrpack() {
    local work_dir=$1
    local output_file=$2
    local variant=$3
    
    log_info "Creating $variant .mrpack archive..."
    
    # Create proper .mrpack structure: modrinth.index.json at root, everything else in overrides/
    local mrpack_dir="${TEMP_BASE}/mrpack_structure_${variant}_$$"
    mkdir -p "$mrpack_dir/overrides"
    
    # Copy modrinth.index.json to root
    cp "$MODRINTH_INDEX" "$mrpack_dir/"
    
    # Copy everything from work_dir into overrides/
    cp -r "$work_dir"/* "$mrpack_dir/overrides/" 2>/dev/null || true
    
    # Create the archive
    local output_path="${BUILDS_OUTPUT_DIR}/${output_file}"
    
    # Try 7z first for faster compression, fallback to zip
    if command -v 7z &> /dev/null; then
        (cd "$mrpack_dir" && 7z a -tzip -mx5 "$output_path" ./* > /dev/null 2>&1)
    else
        (cd "$mrpack_dir" && zip -r -q "$output_path" . 2>/dev/null)
    fi
    
    # Cleanup structure directory
    rm -rf "$mrpack_dir"
    
    if [ -f "$output_path" ]; then
        local size=$(du -h "$output_path" | cut -f1)
        log_success "$variant archive created: $output_path ($size)"
        echo "$output_path"
    else
        log_error "Failed to create $variant archive"
        return 1
    fi
}

# ============================================================================
# Phase 3: Build Client & Server Variants
# ============================================================================

build_variant() {
    local variant=$1
    local output_file=$2
    local -n exclude_list=$3
    
    log_info ""
    log_info "=========================================="
    log_info "Building $variant variant"
    log_info "=========================================="
    
    # Create temporary working directory
    local temp_dir="${TEMP_BASE}/mrpack_${variant}_$$"
    log_info "Using temporary directory: $temp_dir"
    
    mkdir -p "$temp_dir"
    trap "rm -rf '$temp_dir'" EXIT
    
    # Step 1: Copy shared overrides
    copy_overrides "${BUILD_DIR}/overrides" "$temp_dir" "$variant"
    
    # Step 2: Copy variant-specific overrides (these override shared)
    local variant_dir="${BUILD_DIR}/${variant}/overrides"
    if [ -d "$variant_dir" ]; then
        log_info "Applying $variant-specific overrides from $variant_dir"
        copy_overrides "$variant_dir" "$temp_dir" "$variant"
    fi
    
    # Step 3: Copy content directories (mods, resourcepacks, shaderpacks)
    copy_content_dirs "$temp_dir" "$variant"
    
    # Step 4: Apply exclusions AFTER all content is copied
    apply_exclusions "$temp_dir" "$variant" exclude_list
    
    # Step 5: Create the .mrpack archive
    create_mrpack "$temp_dir" "$output_file" "$variant"
    
    # Cleanup handled by trap
    log_success "$variant build complete"
}

# ============================================================================
# Phase 4: Main Execution
# ============================================================================

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║       Modrinth Modpack (.mrpack) Builder                   ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Phase 0: Check & Load
    check_dependencies
    check_build_structure
    load_config
    
    # Phase 1: Initialize
    read_manifest
    prompt_customization
    
    # Create output directory
    mkdir -p "$BUILDS_OUTPUT_DIR"
    log_info "Output directory: $BUILDS_OUTPUT_DIR"
    
    # Phase 2-3: Build variants
    build_variant "client" "$CLIENT_MRPACK" CLIENT_EXCLUDE
    build_variant "server" "$SERVER_MRPACK" SERVER_EXCLUDE
    
    # Summary
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    BUILD COMPLETE ✓                        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    log_success "Archives created in: $BUILDS_OUTPUT_DIR"
    log_success "  - $CLIENT_MRPACK"
    log_success "  - $SERVER_MRPACK"
    echo ""
}

# Run main function
main "$@"
