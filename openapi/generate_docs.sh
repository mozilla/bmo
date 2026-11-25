#!/bin/bash

# Set the source and destination directories
src_dir="../docs/en/rst/api/core/v1"
dest_dir="./docs"

# Ensure the destination directory exists
mkdir -p "$dest_dir"

# Find all RST files recursively in the source directory
find "$src_dir" -type f -name "*.rst" -print0 | while IFS= read -r -d $'\0' rst_file; do
    # Create the corresponding directory structure in the destination directory
    rel_path="${rst_file#$src_dir}"
    dest_file="$dest_dir${rel_path%.rst}.md"
    dest_path=$(dirname "$dest_file")
    mkdir -p "$dest_path"

    # Convert RST to Markdown using Pandoc
    pandoc "$rst_file" -o "$dest_file"

    echo "Converted: $rst_file to $dest_file"
done

echo "Conversion complete!"
