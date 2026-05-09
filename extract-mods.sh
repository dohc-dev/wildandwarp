#!/bin/bash

# Script to extract mod sources from modrinth.index.json and run packwiz add commands
# Supports both Modrinth and CurseForge mods
# Falls back to copying files from .mrpack overrides if packwiz add fails
# Usage: bash extract-mods.sh [modpack_name.mrpack]

# Default values
INDEX_FILE="modrinth.index.json"
MRPACK_EXTRACT="mrpack-extract"
MRPACK_FILE="${1:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Extracting Mods from Modrinth Index ===${NC}"
echo ""

# If mrpack file is provided, extract it
if [ ! -z "$MRPACK_FILE" ]; then
    if [ ! -f "$MRPACK_FILE" ]; then
        echo -e "${RED}Error: $MRPACK_FILE not found${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Extracting modpack: $MRPACK_FILE${NC}"
    
    # Remove existing extraction if present
    if [ -d "$MRPACK_EXTRACT" ]; then
        echo -e "${YELLOW}Removing existing extraction...${NC}"
        # Use timestamped backup to avoid conflicts
        mv "$MRPACK_EXTRACT" "${MRPACK_EXTRACT}-$(date +%s)" 2>/dev/null || true
    fi
    
    # Extract the mrpack
    mkdir -p "$MRPACK_EXTRACT"
    unzip -q "$MRPACK_FILE" -d "$MRPACK_EXTRACT"
    
    if [ ! -f "$MRPACK_EXTRACT/modrinth.index.json" ]; then
        echo -e "${RED}Error: modrinth.index.json not found in $MRPACK_FILE${NC}"
        exit 1
    fi
    
    INDEX_FILE="$MRPACK_EXTRACT/modrinth.index.json"
    echo -e "${GREEN}✓ Modpack extracted${NC}"
    echo ""
fi

if [ ! -f "$INDEX_FILE" ]; then
    echo -e "${RED}Error: $INDEX_FILE not found${NC}"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed${NC}"
    echo "Install it with: sudo apt install jq"
    exit 1
fi

# Initialize log files
ADDED_LOG="mods-added-$(date +%Y%m%d_%H%M%S).log"
FAILED_LOG="mods-failed-$(date +%Y%m%d_%H%M%S).log"
SUCCESS_LOG="mods-success-$(date +%Y%m%d_%H%M%S).log"
FALLBACK_LOG="mods-fallback-$(date +%Y%m%d_%H%M%S).log"

# Function to import file from mrpack using packwiz url command
fallback_url_import() {
    local filename=$1
    local target_path=$2
    
    if [ ! -d "$MRPACK_EXTRACT" ]; then
        return 1
    fi
    
    # First, try exact filename match
    local found_file=$(find "$MRPACK_EXTRACT/overrides" -name "$filename" -type f 2>/dev/null | head -1)
    
    if [ -z "$found_file" ]; then
        # Try fuzzy match
        local base_name=$(echo "$filename" | sed 's/-[0-9].*//' | sed 's/\.zip$//' | sed 's/\.jar$//')
        found_file=$(find "$MRPACK_EXTRACT/overrides" -type f \( -name "$base_name*" -o -name "*$base_name*" \) 2>/dev/null | head -1)
    fi
    
    if [ -z "$found_file" ]; then
        return 1
    fi
    
    # Determine how to classify this file
    local dest_category="mods"
    if [[ "$target_path" == resourcepacks/* ]] || [[ "$found_file" == *"/resourcepacks/"* ]]; then
        dest_category="resourcepacks"
    elif [[ "$target_path" == shaderpacks/* ]] || [[ "$found_file" == *"/shaderpacks/"* ]]; then
        dest_category="shaderpacks"
    fi
    
    # Create temporary copy with proper naming
    local temp_file="/tmp/$(basename "$found_file")"
    cp "$found_file" "$temp_file"
    
    # Try to import via packwiz url command
    local url_cmd="packwiz url add file://$temp_file --meta-folder $dest_category"
    if eval "$url_cmd" 2>/dev/null; then
        echo -e "${YELLOW}✓ Imported via packwiz url:${NC} $(basename "$found_file")"
        echo "packwiz url add file://$(basename "$found_file")" >> "$FALLBACK_LOG"
        rm -f "$temp_file"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Function to find and copy file from mrpack overrides
fallback_copy_file() {
    local filename=$1
    local target_path=$2
    
    if [ ! -d "$MRPACK_EXTRACT" ]; then
        echo -e "${RED}✗ mrpack-extract directory not found${NC}"
        return 1
    fi
    
    # First, try exact filename match
    local found_file=$(find "$MRPACK_EXTRACT/overrides" -name "$filename" -type f 2>/dev/null | head -1)
    
    if [ -z "$found_file" ]; then
        # Try fuzzy match: extract the base name without version for better matching
        local base_name=$(echo "$filename" | sed 's/-[0-9].*//' | sed 's/\.zip$//' | sed 's/\.jar$//')
        
        # Search in all override subdirectories
        found_file=$(find "$MRPACK_EXTRACT/overrides" -type f \( -name "$base_name*" -o -name "*$base_name*" \) 2>/dev/null | head -1)
        
        if [ -z "$found_file" ]; then
            echo -e "${RED}✗ File not found in mrpack overrides${NC}"
            return 1
        fi
    fi
    
    # Determine destination directory
    local dest_dir=""
    if [[ "$target_path" == mods/* ]]; then
        dest_dir="mods"
    elif [[ "$target_path" == resourcepacks/* ]]; then
        dest_dir="resourcepacks"
    elif [[ "$target_path" == shaderpacks/* ]]; then
        dest_dir="shaderpacks"
    else
        dest_dir=$(dirname "$target_path")
    fi
    
    # Create directory if needed
    mkdir -p "$dest_dir"
    
    # Get the actual filename from the found file
    local actual_filename=$(basename "$found_file")
    
    # Copy file
    if cp "$found_file" "$dest_dir/$actual_filename"; then
        echo -e "${YELLOW}✓ Copied from mrpack overrides:${NC} $dest_dir/$actual_filename"
        echo "$actual_filename -> $dest_dir/$actual_filename" >> "$FALLBACK_LOG"
        return 0
    else
        return 1
    fi
}

> "$ADDED_LOG"
> "$FAILED_LOG"
> "$SUCCESS_LOG"
> "$FALLBACK_LOG"

echo -e "${YELLOW}Processing and adding mods...${NC}"
echo ""

# Extract all downloads URLs and paths to a temporary file
# This preserves stdin for interactive prompts later
TEMP_MOD_LIST=$(mktemp)
jq -r '.files[] | "\(.path)|\(.downloads[])"' "$INDEX_FILE" > "$TEMP_MOD_LIST"

# Process mods from the file
while IFS='|' read -r path url; do
    if [ -z "$path" ] || [ -z "$url" ]; then
        continue
    fi
    
    # Determine if it's Modrinth or CurseForge
    if [[ "$url" == *"modrinth"* ]]; then
        # Extract Modrinth project ID from URL
        # URL format: https://cdn.modrinth.com/data/{project-id}/versions/{version-id}/...
        project_id=$(echo "$url" | grep -oP '(?<=/data/)[^/]+' | head -1)
        
        if [ -z "$project_id" ]; then
            filename=$(basename "$path")
            echo -e "${RED}✗ Failed to extract Modrinth ID from:${NC} $filename"
            echo "  URL: $url" >> "$FAILED_LOG"
            continue
        fi
        
        filename=$(basename "$path")
        echo -e "${GREEN}✓ Modrinth:${NC} $filename"
        echo "  Project ID: $project_id"
        
        # Run packwiz modrinth command
        cmd="packwiz mr add $project_id"
        echo "  Running: $cmd"
        if eval "$cmd" 2>/dev/null; then
            echo "$cmd" >> "$SUCCESS_LOG"
            echo "    ✓ Added successfully (Modrinth)"
        else
            echo "    ✗ Failed via Modrinth, trying CurseForge..."
            # Try CurseForge as fallback
            cf_cmd="packwiz cf add $project_id"
            if eval "$cf_cmd" 2>/dev/null; then
                echo "$cf_cmd" >> "$SUCCESS_LOG"
                echo "    ✓ Added successfully (CurseForge)"
            else
                echo "    ✗ Failed via CurseForge, trying url import..."
                # Try url import from mrpack
                if fallback_url_import "$filename" "$path"; then
                    echo "$cmd (url-import)" >> "$SUCCESS_LOG"
                else
                    echo "    ✗ Failed via url import, trying direct copy..."
                    # Try to copy from mrpack overrides
                    if fallback_copy_file "$filename" "$path"; then
                        echo "$cmd (direct-copy)" >> "$SUCCESS_LOG"
                    else
                        echo "$cmd" >> "$FAILED_LOG"
                        echo "    ✗ All fallbacks failed"
                    fi
                fi
            fi
        fi
        
    elif [[ "$url" == *"curseforge"* ]] || [[ "$url" == *"curse.com"* ]]; then
        # Extract CurseForge project ID and file ID from URL
        # URL format: https://edge.forgecdn.net/files/{folder}/{file}/...
        # Or: https://www.curseforge.com/api/v1/mods/{project-id}/files/{file-id}/download
        
        if [[ "$url" == *"/api/v1/mods/"* ]]; then
            project_id=$(echo "$url" | grep -oP '(?<=/mods/)[^/]+' | head -1)
            file_id=$(echo "$url" | grep -oP '(?<=/files/)[^/]+' | head -1)
        else
            # Parse from edge.forgecdn.net format
            # Files are organized like: /files/XXXX/YYYYY/filename.jar
            file_path=$(echo "$url" | grep -oP '(?<=/files/).+(?=/)' | tail -1)
            if [ ! -z "$file_path" ]; then
                project_id=$(echo "$file_path" | cut -d'/' -f1)
                file_id=$(echo "$file_path" | cut -d'/' -f2)
            fi
        fi
        
        if [ -z "$project_id" ]; then
            filename=$(basename "$path")
            echo -e "${RED}✗ Failed to extract CurseForge ID from:${NC} $filename"
            echo "  URL: $url" >> "$FAILED_LOG"
            continue
        fi
        
        filename=$(basename "$path")
        echo -e "${YELLOW}✓ CurseForge:${NC} $filename"
        echo "  Project ID: $project_id"
        
        # Run packwiz curseforge command
        cmd="packwiz cf add $project_id"
        echo "  Running: $cmd"
        if eval "$cmd" 2>/dev/null; then
            echo "$cmd" >> "$SUCCESS_LOG"
            echo "    ✓ Added successfully (CurseForge)"
        else
            echo "    ✗ Failed via CurseForge, trying Modrinth..."
            # Try Modrinth as fallback
            mr_cmd="packwiz mr add $project_id"
            if eval "$mr_cmd" 2>/dev/null; then
                echo "$mr_cmd" >> "$SUCCESS_LOG"
                echo "    ✓ Added successfully (Modrinth)"
            else
                echo "    ✗ Failed via Modrinth, trying url import..."
                # Try url import from mrpack
                if fallback_url_import "$filename" "$path"; then
                    echo "$cmd (url-import)" >> "$SUCCESS_LOG"
                else
                    echo "    ✗ Failed via url import, trying direct copy..."
                    # Try to copy from mrpack overrides
                    if fallback_copy_file "$filename" "$path"; then
                        echo "$cmd (direct-copy)" >> "$SUCCESS_LOG"
                    else
                        echo "$cmd" >> "$FAILED_LOG"
                        echo "    ✗ All fallbacks failed"
                    fi
                fi
            fi
        fi
    else
        # Unknown source
        filename=$(basename "$path")
        echo -e "${YELLOW}⚠ Unknown source:${NC} $filename"
        echo "  URL: $url"
        echo "$url" >> "$FAILED_LOG"
    fi
done < "$TEMP_MOD_LIST"

# Clean up temp file
rm -f "$TEMP_MOD_LIST"

echo ""
echo -e "${BLUE}=== Summary ===${NC}"
success_count=$(grep -c "." "$SUCCESS_LOG" 2>/dev/null || echo 0)
failed_count=$(grep -c "." "$FAILED_LOG" 2>/dev/null || echo 0)
fallback_count=$(grep -c "." "$FALLBACK_LOG" 2>/dev/null || echo 0)

echo -e "Successfully added: ${GREEN}$success_count${NC}"
echo -e "Fallback copies: ${YELLOW}$fallback_count${NC}"
echo -e "Failed: ${RED}$failed_count${NC}"

echo ""
echo -e "${BLUE}=== Results ===${NC}"

if [ $success_count -gt 0 ]; then
    echo -e "${GREEN}Successfully added:${NC}"
    cat "$SUCCESS_LOG"
    echo ""
fi

if [ $fallback_count -gt 0 ]; then
    echo -e "${YELLOW}Fallback copies from mrpack:${NC}"
    cat "$FALLBACK_LOG"
    echo ""
fi

if [ $failed_count -gt 0 ]; then
    echo -e "${RED}Failed to add:${NC}"
    cat "$FAILED_LOG"
    echo ""
fi

echo -e "${YELLOW}Log files:${NC}"
echo -e "  Success: ${GREEN}$SUCCESS_LOG${NC}"
if [ $fallback_count -gt 0 ]; then
    echo -e "  Fallback: ${YELLOW}$FALLBACK_LOG${NC}"
fi
echo -e "  Failed: ${RED}$FAILED_LOG${NC}"

# Handle missing files interactively if there are failures
if [ $failed_count -gt 0 ]; then
    echo ""
    echo -e "${BLUE}=== Handling Missing Files ===${NC}"
    echo ""
    
    while IFS= read -r failed_entry; do
        if [ -z "$failed_entry" ]; then
            continue
        fi
        
        # Extract the mod name for display
        mod_name=$(echo "$failed_entry" | sed 's/packwiz .* add //' | sed 's/ (.*//')
        
        echo -e "${YELLOW}Missing mod:${NC} $mod_name"
        echo "Options:"
        echo "  [s] Skip this mod"
        echo "  [u] Provide URL to download"
        echo "  [f] Provide local file path"
        echo ""
        read -p "Choose action [s/u/f]: " action
        
        case $action in
            u|U)
                read -p "Enter download URL: " dl_url
                if [ ! -z "$dl_url" ]; then
                    # Download the file
                    temp_file="/tmp/temp_$(date +%s).jar"
                    if curl -s -L "$dl_url" -o "$temp_file"; then
                        # Determine destination directory
                        dest_dir="mods"
                        if [[ "$mod_name" == *"pack" ]]; then
                            dest_dir="resourcepacks"
                        elif [[ "$mod_name" == *"shader" ]]; then
                            dest_dir="shaderpacks"
                        fi
                        
                        mkdir -p "$dest_dir"
                        filename=$(basename "$temp_file")
                        if cp "$temp_file" "$dest_dir/$filename"; then
                            echo -e "${GREEN}✓ Downloaded and added: $dest_dir/$filename${NC}"
                            echo "Downloaded: $mod_name" >> "$SUCCESS_LOG"
                        else
                            echo -e "${RED}✗ Failed to copy file${NC}"
                        fi
                        rm -f "$temp_file"
                    else
                        echo -e "${RED}✗ Failed to download from URL${NC}"
                    fi
                fi
                ;;
            f|F)
                read -p "Enter local file path: " file_path
                if [ -f "$file_path" ]; then
                    # Determine destination directory
                    dest_dir="mods"
                    if [[ "$mod_name" == *"pack" ]]; then
                        dest_dir="resourcepacks"
                    elif [[ "$mod_name" == *"shader" ]]; then
                        dest_dir="shaderpacks"
                    fi
                    
                    mkdir -p "$dest_dir"
                    filename=$(basename "$file_path")
                    if cp "$file_path" "$dest_dir/$filename"; then
                        echo -e "${GREEN}✓ Copied: $dest_dir/$filename${NC}"
                        echo "Copied: $mod_name" >> "$SUCCESS_LOG"
                    else
                        echo -e "${RED}✗ Failed to copy file${NC}"
                    fi
                else
                    echo -e "${RED}✗ File not found: $file_path${NC}"
                fi
                ;;
            s|S|"")
                echo -e "${YELLOW}Skipped: $mod_name${NC}"
                ;;
            *)
                echo -e "${YELLOW}Invalid option, skipping...${NC}"
                ;;
        esac
        echo ""
    done < "$FAILED_LOG"
fi
