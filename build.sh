#!/bin/bash
if [ ! -d "build" ]; then
    echo "Creating build folder..."
    mkdir -p build
fi

odin build src/ -out:build/orion -o:speed -show-timings
