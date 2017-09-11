#!/bin/bash

qemu-system-i386 -s -S -drive format=raw,file=bootsnake.bin &
gnome-terminal --command="gdb bootsnake.asm -ex \"target remote localhost:1234\""
