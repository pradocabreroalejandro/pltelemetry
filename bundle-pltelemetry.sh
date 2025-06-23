#!/bin/bash

# bundle-all.sh
# Automatically finds and bundles all project files

OUTPUT_FILE="pltelemetry-complete-bundle.txt"
PROJECT_ROOT="${1:-.}"  # Use first argument or current directory

# Extensions to include
EXTENSIONS="sql pks pkb md txt conf sh yml json"

# Directories to exclude
EXCLUDE_DIRS=".git node_modules target build dist"

# Clear or create output file
> "$OUTPUT_FILE"

# Header
cat << EOF >> "$OUTPUT_FILE"
========================================================================
PLTelemetry Complete Source Bundle
Generated on: $(date)
From: $(pwd)
========================================================================

TABLE OF CONTENTS:
EOF

# First pass: generate table of contents
echo "" >> "$OUTPUT_FILE"
echo "Finding files..."

file_count=0
for ext in $EXTENSIONS; do
    while IFS= read -r file; do
        # Skip excluded directories
        skip=false
        for exclude in $EXCLUDE_DIRS; do
            if [[ "$file" == *"/$exclude/"* ]]; then
                skip=true
                break
            fi
        done
        
        if [ "$skip" = false ]; then
            echo "$file" >> "$OUTPUT_FILE"
            ((file_count++))
        fi
    done < <(find "$PROJECT_ROOT" -type f -name "*.$ext" 2>/dev/null | sort)
done

echo "" >> "$OUTPUT_FILE"
echo "========================================================================" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Second pass: add file contents
echo "Adding $file_count files to bundle..."

for ext in $EXTENSIONS; do
    while IFS= read -r file; do
        # Skip excluded directories
        skip=false
        for exclude in $EXCLUDE_DIRS; do
            if [[ "$file" == *"/$exclude/"* ]]; then
                skip=true
                break
            fi
        done
        
        if [ "$skip" = false ]; then
            # Remove ./ prefix if present
            display_path="${file#./}"
            
            cat << EOF >> "$OUTPUT_FILE"

========================================================================
FILE: $display_path
SIZE: $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "unknown") bytes
MODIFIED: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || stat -c "%y" "$file" 2>/dev/null | cut -d' ' -f1-2 || echo "unknown")
========================================================================

EOF
            cat "$file" >> "$OUTPUT_FILE"
            echo "" >> "$OUTPUT_FILE"
            echo "[END OF FILE: $display_path]" >> "$OUTPUT_FILE"
            echo "" >> "$OUTPUT_FILE"
        fi
    done < <(find "$PROJECT_ROOT" -type f -name "*.$ext" 2>/dev/null | sort)
done

# Summary
cat << EOF >> "$OUTPUT_FILE"

========================================================================
BUNDLE SUMMARY
========================================================================
Total files: $file_count
Bundle size: $(du -h "$OUTPUT_FILE" | cut -f1)
Total lines: $(wc -l < "$OUTPUT_FILE")
Generated: $(date)
========================================================================
EOF

echo "✅ Bundle created: $OUTPUT_FILE"
echo "📊 Statistics:"
echo "   - Files included: $file_count"
echo "   - Bundle size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo "   - Total lines: $(wc -l < "$OUTPUT_FILE")"

# Optional: Create compressed version
if command -v gzip &> /dev/null; then
    gzip -c "$OUTPUT_FILE" > "${OUTPUT_FILE}.gz"
    echo "   - Compressed: ${OUTPUT_FILE}.gz ($(du -h "${OUTPUT_FILE}.gz" | cut -f1))"
fi