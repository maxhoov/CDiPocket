/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "disc.h"
#define REG(offset) (*(volatile u32 *)(0x80000000u+(offset)))
#define BRIDGE(pointer) (0x60000000u+(u32)(pointer))
#define BIN_SLOT 4
#define SECTOR ((u8 *)0x1e000)
static Disc disc;
static char cue[CUE_MAX_BYTES+4] __attribute__((aligned(4)));
static u8 path_struct[264] __attribute__((aligned(4)));
static char cue_path[256];
static char active_path[256];

static u32 equal(const char *a,const char *b) {
    while (*a && *a==*b) {++a;++b;}return *a==*b;
}
static u32 operation(u32 op,u32 slot,u32 offset,u32 address,u32 length) {
    while (REG(0x18)&1) {}
    REG(0x04)=slot;REG(0x08)=offset;REG(0x0c)=address;REG(0x10)=length;
    REG(0x14)=op;
    while (REG(0x18)&1) {}
    return REG(0x18)>>8;
}
static u32 slot_size(u32 id) {
    /* APF size table order is independent of a slot's numeric ID. */
    for (u32 i=0;i<32;++i) {
        if ((REG(0x100+i*8)&0xffff)==id) return REG(0x104+i*8);
    }
    return 0;
}
static u32 open_bin(const char *path) {
    if (equal(path,active_path)) return 0;
    memset(path_struct,0,sizeof(path_struct));
    for (u32 i=0;path[i] && i<255;++i) path_struct[i]=(u8)path[i];
    u32 error=operation(3,BIN_SLOT,0,BRIDGE(path_struct),0);
    if (error) { active_path[0]=0;return error; }
    for (u32 i=0;i<256;++i) active_path[i]=path[i];
    return 0;
}
static u32 file_size(const char *path) {
    if (open_bin(path)) return 0;
    return slot_size(BIN_SLOT);
}
static u32 read_bin(const char *path,u32 offset,u8 *out,u32 length) {
    if (open_bin(path)) return 1;
    return operation(1,BIN_SLOT,offset,BRIDGE(out),length);
}
static void failed(u32 code,u32 phase) {
    REG(0x24)=(phase<<16)|code;
    for (;;) {}
}
void main(void) {
    REG(0x24)=0x10000;
    while (!(REG(0x00)&1)) {}
    memset(path_struct,0,sizeof(path_struct));
    if (operation(2,0,0,BRIDGE(path_struct),0)) failed(DISC_FILE,1);
    u32 length=0;
    while (length<255 && path_struct[length]) {cue_path[length]=(char)path_struct[length];++length;}
    cue_path[length]=0;
    length=REG(0x28);
    if (!length || length>CUE_MAX_BYTES) failed(DISC_RANGE,2);
    REG(0x24)=0x20000;
    if (operation(1,0,0,BRIDGE(cue),length)) failed(DISC_FILE,2);
    REG(0x24)=0x30000;
    u32 error=disc_parse(&disc,cue,length,cue_path,file_size);
    if (error) failed(error,3);
    REG(0x20)=1;REG(0x24)=0;
    for (;;) {
        if (REG(0x2c)&1) {
            u32 token=REG(0x34),lba=REG(0x30);
            error=disc_sector(&disc,lba,SECTOR,read_bin);
            REG(0x38)=(token<<8)|error;
            /* Buffer ownership returns only after the full sector streams. */
            while (REG(0x2c)&2) {}
        }
    }
}
