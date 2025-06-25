#!/bin/bash

# bundle-light.sh
# Automatically finds and bundles project files (first 100 lines only)

OUTPUT_FILE="pltelemetry-light-bundle.txt"
PROJECT_ROOT="${1:-.}"  # Use first argument or current directory
MAX_LINES=100           # Maximum lines per file

# Extensions to include
EXTENSIONS="sql pks pkb md txt conf sh yml json"

# Directories to exclude
EXCLUDE_DIRS=".git node_modules target build dist"

# Clear or create output file
> "$OUTPUT_FILE"

# Header
cat << EOF >> "$OUTPUT_FILE"
========================================================================
PLTelemetry Light Source Bundle (First $MAX_LINES lines per file)
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
            total_lines=$(wc -l < "$file" 2>/dev/null || echo "0")
            echo "$file (lines: $total_lines, showing: $(($total_lines > $MAX_LINES ? $MAX_LINES : $total_lines)))" >> "$OUTPUT_FILE"
            ((file_count++))
        fi
    done < <(find "$PROJECT_ROOT" -type f -name "*.$ext" 2>/dev/null | sort)
done

echo "" >> "$OUTPUT_FILE"
echo "========================================================================" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Second pass: add file contents (limited)
echo "Adding $file_count files to bundle (max $MAX_LINES lines each)..."

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
            total_lines=$(wc -l < "$file" 2>/dev/null || echo "0")
            
            cat << EOF >> "$OUTPUT_FILE"

========================================================================
FILE: $display_path
SIZE: $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "unknown") bytes
TOTAL LINES: $total_lines
SHOWING: $(($total_lines > $MAX_LINES ? $MAX_LINES : $total_lines)) lines
MODIFIED: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || stat -c "%y" "$file" 2>/dev/null | cut -d' ' -f1-2 || echo "unknown")
========================================================================

EOF
            # Only show first MAX_LINES lines
            head -n $MAX_LINES "$file" >> "$OUTPUT_FILE"
            
            # Add truncation notice if file was cut
            if [ "$total_lines" -gt "$MAX_LINES" ]; then
                echo "" >> "$OUTPUT_FILE"
                echo "[... TRUNCATED - Showing first $MAX_LINES of $total_lines lines ...]" >> "$OUTPUT_FILE"
            fi
            
            echo "" >> "$OUTPUT_FILE"
            echo "[END OF FILE: $display_path]" >> "$OUTPUT_FILE"
            echo "" >> "$OUTPUT_FILE"
        fi
    done < <(find "$PROJECT_ROOT" -type f -name "*.$ext" 2>/dev/null | sort)
done

# Summary
cat << EOF >> "$OUTPUT_FILE"

========================================================================
LIGHT BUNDLE SUMMARY
========================================================================
Total files: $file_count
Max lines per file: $MAX_LINES
Bundle size: $(du -h "$OUTPUT_FILE" | cut -f1)
Total bundle lines: $(wc -l < "$OUTPUT_FILE")
Generated: $(date)

NOTE: This is a light version showing only the first $MAX_LINES lines of each file
      Use bundle-all.sh for complete files
========================================================================
EOF

echo "✅ Light bundle created: $OUTPUT_FILE"
echo "📊 Statistics:"
echo "   - Files included: $file_count"
echo "   - Max lines per file: $MAX_LINES"
echo "   - Bundle size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo "   - Total lines: $(wc -l < "$OUTPUT_FILE")"

# Optional: Create compressed version
if command -v gzip &> /dev/null; then
    gzip -c "$OUTPUT_FILE" > "${OUTPUT_FILE}.gz"
    echo "   - Compressed: ${OUTPUT_FILE}.gz ($(du -h "${OUTPUT_FILE}.gz" | cut -f1))"
fi