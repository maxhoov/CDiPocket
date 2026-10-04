/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef CDI_NATIVE_DISC_H
#define CDI_NATIVE_DISC_H
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed int s32;
#define MAX_TRACKS 99
#define CUE_MAX_BYTES 32768
#define RAW_BYTES 2352
#define RECORD_BYTES 2568
enum { DISC_OK=0, DISC_CUE_SYNTAX=1, DISC_UNSUPPORTED=2, DISC_PATH=3,
       DISC_FILE=4, DISC_GEOMETRY=5, DISC_RANGE=6, DISC_DATA=7 };
typedef struct {
    u32 file, mode, index0, index1, pregap, start, index1_absolute, end;
    u8 control, has_index0, has_index1, has_pregap;
} Track;
typedef struct {
    char path[256];
    u32 sectors;
} BinFile;
typedef struct {
    Track tracks[MAX_TRACKS];
    BinFile files[MAX_TRACKS];
    u32 track_count, file_count, leadout;
} Disc;
typedef u32 (*SizeCallback)(const char *path);
typedef u32 (*ReadCallback)(const char *path, u32 offset, u8 *destination, u32 bytes);
u32 disc_parse(Disc *disc, char *cue, u32 length, const char *cue_path, SizeCallback size);
u32 disc_sector(const Disc *disc, u32 lba, u8 *record, ReadCallback read);
void *memset(void *dst, int value, u32 count);
void *memcpy(void *dst, const void *src, u32 count);
u32 __udivsi3(u32 a, u32 b);
u32 __umodsi3(u32 a, u32 b);
#endif
