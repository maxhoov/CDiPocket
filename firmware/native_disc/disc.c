/* SPDX-License-Identifier: GPL-3.0-or-later
 * Native raw CUE/BIN layout and Q subchannel generation. No disc conversion.
 */
#include "disc.h"

void *memset(void *dst, int value, u32 count) {
    u8 *out = (u8 *)dst;
    while (count--) *out++ = (u8)value;
    return dst;
}
void *memcpy(void *dst, const void *src, u32 count) {
    u8 *out = (u8 *)dst; const u8 *in = (const u8 *)src;
    while (count--) *out++ = *in++;
    return dst;
}

#ifndef HOST_TEST
/* Freestanding RV32I runtime: no compiler-rt or integer multiplier needed. */
static u32 divide(u32 a, u32 b, u32 *remainder) {
    u32 result = 0, rest = 0;
    if (!b) { *remainder = a; return ~0u; }
    for (u32 bit = 32; bit; --bit) {
        u32 high = rest >> 31;
        rest = (rest << 1) | ((a >> (bit - 1)) & 1);
        if (high || rest >= b) { rest -= b; result |= 1u << (bit - 1); }
    }
    *remainder = rest; return result;
}
u32 __udivsi3(u32 a, u32 b) { u32 r; return divide(a,b,&r); }
u32 __umodsi3(u32 a, u32 b) { u32 r; divide(a,b,&r); return r; }
u32 __mulsi3(u32 a, u32 b) {
    u32 result = 0;
    while (b) { if (b&1) result += a; a <<= 1; b >>= 1; }
    return result;
}
#endif

static u32 equal(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
static u8 upper(u8 value) {
    return value >= 'a' && value <= 'z' ? value - 32 : value;
}
static u32 keyword(const char *a, const char *b) {
    while (*a && upper((u8)*a) == (u8)*b) { ++a; ++b; }
    return !*a && !*b;
}
static u32 number(const char *text, u32 *value) {
    u32 result = 0, digits = 0;
    while (*text) {
        if (*text < '0' || *text > '9' || result > 1000000) return 0;
        result = result * 10 + (u8)*text++ - '0'; ++digits;
    }
    *value = result; return digits != 0;
}
static u32 time_frames(const char *text, u32 *value) {
    u32 fields[3] = {0,0,0}, field = 0, digits = 0;
    while (*text) {
        if (*text == ':') {
            if (!digits || field >= 2) return 0;
            ++field; digits = 0;
        } else {
            if (*text < '0' || *text > '9' || fields[field] > 99) return 0;
            fields[field] = fields[field] * 10 + (u8)*text - '0'; ++digits;
        }
        ++text;
    }
    if (field != 2 || !digits || fields[0] > 99 || fields[1] >= 60 || fields[2] >= 75) return 0;
    *value = (fields[0] * 60 + fields[1]) * 75 + fields[2]; return 1;
}

/* Resolve . and .. before passing the absolute Assets path to APF. */
static u32 resolve_path(char *out, const char *base, const char *name) {
    char combined[512]; u32 length = 0, used = 0;
    if (name[0] != '/') {
        u32 last = 0;
        for (u32 i = 0; base[i]; ++i) if (base[i] == '/' || base[i] == '\\') last = i + 1;
        for (u32 i = 0; i < last; ++i) combined[length++] = base[i];
    }
    for (u32 i = 0; name[i]; ++i) {
        if (length >= 510 || name[i] == ':') return 0;
        combined[length++] = name[i] == '\\' ? '/' : name[i];
    }
    combined[length] = 0;
    if (combined[0] != '/') return 0;
    out[used++] = '/';
    for (u32 i = 1; i < length;) {
        while (combined[i] == '/') ++i;
        u32 start = i;
        while (combined[i] && combined[i] != '/') ++i;
        u32 count = i - start;
        if (!count || (count == 1 && combined[start] == '.')) continue;
        if (count == 2 && combined[start] == '.' && combined[start+1] == '.') {
            if (used <= 1) return 0;
            --used; while (used > 1 && out[used-1] != '/') --used;
            continue;
        }
        if (used + count + 1 >= 256) return 0;
        for (u32 j = 0; j < count; ++j) out[used++] = combined[start+j];
        out[used++] = '/';
    }
    if (used <= 1) return 0;
    out[--used] = 0;
    const char prefix[] = "/Assets/";
    for (u32 i = 0; i < 8; ++i) if (out[i] != prefix[i]) return 0;
    return 1;
}

/* In-place tokens with quoted filenames, CRLF, tabs, and UTF-8 filenames. */
static s32 tokens(char *line, char **result, u32 capacity) {
    u32 count = 0;
    while (*line) {
        while (*line == ' ' || *line == '\t' || *line == '\r') ++line;
        if (!*line) break;
        if (count == capacity) return -1;
        if (*line == '"') {
            result[count++] = ++line;
            while (*line && *line != '"') ++line;
            if (!*line) return -1;
            *line++ = 0;
            if (*line && *line != ' ' && *line != '\t' && *line != '\r') return -1;
        } else {
            result[count++] = line;
            while (*line && *line != ' ' && *line != '\t' && *line != '\r') ++line;
            if (*line) *line++ = 0;
        }
    }
    return (s32)count;
}

u32 disc_parse(Disc *disc, char *cue, u32 length, const char *cue_path, SizeCallback size) {
    memset(disc,0,sizeof(*disc));
    if (!length || length > CUE_MAX_BYTES) return DISC_RANGE;
    cue[length] = 0;
    u32 current_file = ~0u;
    char *line = cue;
    if (length >= 3 && (u8)line[0] == 0xef && (u8)line[1] == 0xbb && (u8)line[2] == 0xbf) line += 3;
    while (*line) {
        char *next = line;
        while (*next && *next != '\n') ++next;
        if (*next) *next++ = 0;
        /* Metadata text need not fit the short command token vector. */
        char *command = line;
        while (*command == ' ' || *command == '\t' || *command == '\r') ++command;
        char *end = command;
        while (*end && *end != ' ' && *end != '\t' && *end != '\r') ++end;
        char separator = *end; *end = 0;
        u32 ignored = keyword(command,"REM") || keyword(command,"TITLE") ||
            keyword(command,"PERFORMER") || keyword(command,"CATALOG") ||
            keyword(command,"ISRC") || keyword(command,"SONGWRITER");
        *end = separator;
        if (!ignored) {
            char *word[8]; s32 count = tokens(line,word,8);
            if (count < 0) return DISC_CUE_SYNTAX;
            if (count) {
                Track *track = disc->track_count ? &disc->tracks[disc->track_count-1] : (Track *)0;
                if (keyword(word[0],"FILE")) {
                    if (count != 3 || !*word[1]) return DISC_CUE_SYNTAX;
                    if (!keyword(word[2],"BINARY")) return DISC_UNSUPPORTED;
                    char path[256];
                    if (!resolve_path(path,cue_path,word[1])) return DISC_PATH;
                    current_file = 0;
                    while (current_file < disc->file_count && !equal(path,disc->files[current_file].path)) ++current_file;
                    if (current_file == disc->file_count) {
                        if (disc->file_count == MAX_TRACKS) return DISC_RANGE;
                        u32 bytes = size(path);
                        if (!bytes) return DISC_FILE;
                        if (bytes % RAW_BYTES || bytes / RAW_BYTES >= 450000) return DISC_GEOMETRY;
                        memcpy(disc->files[current_file].path,path,256);
                        disc->files[current_file].sectors = bytes / RAW_BYTES;
                        ++disc->file_count;
                    }
                } else if (keyword(word[0],"TRACK")) {
                    u32 id;
                    if (count != 3 || current_file == ~0u || !number(word[1],&id)) return DISC_CUE_SYNTAX;
                    if (id != disc->track_count + 1 || id > MAX_TRACKS) return DISC_GEOMETRY;
                    track = &disc->tracks[disc->track_count++];
                    track->file = current_file;
                    if (keyword(word[2],"AUDIO")) { track->mode=0;track->control=0x01; }
                    else if (keyword(word[2],"MODE1/2352")) { track->mode=1;track->control=0x41; }
                    else if (keyword(word[2],"MODE2/2352") || keyword(word[2],"CDI/2352")) {
                        track->mode=2;track->control=0x41;
                    }
                    else return DISC_UNSUPPORTED;
                } else if (keyword(word[0],"INDEX")) {
                    u32 id, frames;
                    if (count != 3 || !track || !number(word[1],&id) || !time_frames(word[2],&frames)) return DISC_CUE_SYNTAX;
                    if (id > 1) return DISC_UNSUPPORTED;
                    if (id == 0) {
                        if (track->has_index0 || track->has_index1) return DISC_GEOMETRY;
                        track->index0 = frames; track->has_index0 = 1;
                    } else {
                        if (track->has_index1) return DISC_GEOMETRY;
                        track->index1 = frames; track->has_index1 = 1;
                    }
                } else if (keyword(word[0],"PREGAP")) {
                    if (count != 2 || !track || track->has_pregap || !time_frames(word[1],&track->pregap)) return DISC_CUE_SYNTAX;
                    track->has_pregap = 1;
                } else if (keyword(word[0],"FLAGS")) {
                    if (count < 2 || !track) return DISC_CUE_SYNTAX;
                    for (s32 i = 1; i < count; ++i) {
                        if (keyword(word[i],"PRE")) track->control |= 0x10;
                        else if (keyword(word[i],"DCP")) track->control |= 0x20;
                        else if (keyword(word[i],"4CH")) track->control |= 0x80;
                        else return DISC_UNSUPPORTED;
                    }
                } else return DISC_UNSUPPORTED;
            }
        }
        line = next;
    }
    if (!disc->track_count) return DISC_CUE_SYNTAX;
    for (u32 i = 0; i < disc->track_count; ++i) {
        Track *track = &disc->tracks[i];
        if (!track->has_index1) return DISC_GEOMETRY;
        if (!track->has_index0) track->index0 = track->index1;
        if (track->index0 > track->index1) return DISC_GEOMETRY;
    }
    Track *first = &disc->tracks[0];
    u32 first_gap = first->pregap + first->index1 - first->index0;
    if (first_gap > 150) return DISC_GEOMETRY;
    u32 cursor = 150 - first_gap;
    for (u32 i = 0; i < disc->track_count; ++i) {
        Track *track = &disc->tracks[i];
        u32 end = disc->files[track->file].sectors;
        if (i + 1 < disc->track_count && disc->tracks[i+1].file == track->file)
            end = disc->tracks[i+1].index0;
        if (track->index1 >= end || end > disc->files[track->file].sectors || track->pregap > 450000)
            return DISC_GEOMETRY;
        track->start = cursor;
        track->index1_absolute = cursor + track->pregap + track->index1 - track->index0;
        cursor += track->pregap + end - track->index0;
        track->end = cursor;
        if (cursor + 128 >= 450000) return DISC_GEOMETRY;
    }
    disc->leadout = cursor;
    return DISC_OK;
}

static u8 bcd(u32 value) { return (u8)((value/10)*16 + value%10); }
static void msf(u8 *out, u32 frames) {
    u32 minutes = frames/4500; frames %= 4500;
    out[0]=bcd(minutes); out[1]=bcd(frames/75); out[2]=bcd(frames%75);
}
static void q_tail(u8 *record, const u8 *q) {
    u16 crc = 0;
    for (u32 i = 0; i < 10; ++i) {
        crc ^= (u16)q[i] << 8;
        for (u32 bit = 0; bit < 8; ++bit) crc = (u16)((crc << 1) ^ ((crc&0x8000) ? 0x1021 : 0));
        record[RAW_BYTES+2*i]=0;record[RAW_BYTES+2*i+1]=q[i];
    }
    crc ^= 0xffff;
    record[RAW_BYTES+20]=0;record[RAW_BYTES+21]=(u8)(crc>>8);
    record[RAW_BYTES+22]=0;record[RAW_BYTES+23]=(u8)crc;
    memset(record+RAW_BYTES+24,0,192);
}

/* The table is initialized once. Reading a scrambled sector is bytewise XOR,
 * without performing 18,720 LFSR iterations for every sector. */
static u8 scramble[2340];
static u32 scramble_ready;
static void init_scramble(void) {
    if (scramble_ready) return;
    u32 shift = 1;
    for (u32 i = 0; i < 2340; ++i) {
        u32 value = 0;
        for (u32 bit = 0; bit < 8; ++bit) {
            value |= (shift&1) << bit;
            u32 feedback = (shift ^ (shift>>1))&1;
            shift = (shift>>1)|(feedback<<14);
        }
        scramble[i] = (u8)value;
    }
    scramble_ready=1;
}
u32 disc_sector(const Disc *disc, u32 lba, u8 *record, ReadCallback read) {
    u8 q[10]; memset(q,0,10);
    const Track *first=&disc->tracks[0], *last=&disc->tracks[disc->track_count-1];
    if (lba & 0x80000000u) {
        u32 sequence=lba&127, point=sequence%(disc->track_count+3);
        memset(record,0,RAW_BYTES); q[0]=first->control;msf(q+3,sequence);
        if (point==0) { q[2]=0xa0;q[7]=1;q[8]=first->mode==2 ? 0x10 : 0; }
        else if (point==1) { q[0]=last->control;q[2]=0xa1;q[7]=bcd(disc->track_count); }
        else if (point==2) { q[0]=last->control;q[2]=0xa2;msf(q+7,disc->leadout); }
        else { const Track *t=&disc->tracks[point-3];q[0]=t->control;q[2]=bcd(point-2);msf(q+7,t->index1_absolute); }
    } else {
        if (lba >= disc->leadout+128) return DISC_RANGE;
        const Track *t=first;u32 track_number=0;
        if (lba >= disc->leadout) {
            memset(record,0,RAW_BYTES);q[0]=last->control;q[1]=0xaa;q[2]=1;
            msf(q+3,lba-disc->leadout);msf(q+7,lba);
        } else {
            while (track_number+1 < disc->track_count && lba >= disc->tracks[track_number+1].start) ++track_number;
            t=&disc->tracks[track_number];
            u32 source_begin=t->start+t->pregap;
            if (lba < source_begin) memset(record,0,RAW_BYTES);
            else {
                u32 source=lba-source_begin+t->index0;
                if (read(disc->files[t->file].path,source*RAW_BYTES,record,RAW_BYTES)) return DISC_FILE;
                if (t->mode) {
                    if (record[0] || record[11]) return DISC_DATA;
                    for (u32 i=1;i<11;++i) if (record[i]!=0xff) return DISC_DATA;
                    u8 expected[4];msf(expected,lba);expected[3]=(u8)t->mode;
                    u32 plain=1, encoded=1;init_scramble();
                    for (u32 i=0;i<4;++i) {
                        if (record[12+i]!=expected[i]) plain=0;
                        if ((record[12+i]^scramble[i])!=expected[i]) encoded=0;
                    }
                    if (!plain && encoded) for (u32 i=0;i<2340;++i) record[12+i]^=scramble[i];
                    if (record[15] != t->mode) return DISC_DATA;
                }
            }
            q[0]=t->control;q[1]=bcd(track_number+1);
            q[2]=lba >= t->index1_absolute ? 1 : 0;
            msf(q+3,lba >= t->index1_absolute ? lba-t->index1_absolute : t->index1_absolute-lba);
            msf(q+7,lba);
        }
    }
    q_tail(record,q);return DISC_OK;
}
