#!/bin/bash
METAL_FILE="$1"
COMMON_HEADER="$2"
IMPL_HEADER="$3"
OUTPUT="$4"

sed -e "/#include \"ggml-common.h\"/r $COMMON_HEADER" -e "/#include \"ggml-common.h\"/d" \
    -e "/#include \"ggml-metal-impl.h\"/r $IMPL_HEADER" -e "/#include \"ggml-metal-impl.h\"/d" \
    "$METAL_FILE" > "$OUTPUT"
