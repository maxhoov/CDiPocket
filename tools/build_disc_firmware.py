"""Build the embedded, open-source CUE/BIN manager. No user ROM is involved."""
from pathlib import Path
import argparse
import struct
import subprocess

ROOT=Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--llvm-bin',type=Path,default=Path('D:/Development/LLVM-23.1.1/bin'))
    args=parser.parse_args()
    source=ROOT/'firmware/native_disc'
    output=ROOT/'build/disc_firmware'
    output.mkdir(parents=True,exist_ok=True)
    elf=output/'native_disc.elf'
    subprocess.run([str(args.llvm_bin/'clang.exe'),'--target=riscv32-unknown-elf',
        '-march=rv32i','-mabi=ilp32','-O2','-ffreestanding','-fno-builtin',
        '-fno-stack-protector','-mno-relax','-nostdlib','-fuse-ld=lld',
        '-Wl,--gc-sections','-Wl,-T,'+str(source/'link.ld'),
        str(source/'start.S'),str(source/'main.c'),str(source/'disc.c'),'-o',str(elf)],check=True)
    binary=output/'native_disc.bin'
    subprocess.run([str(args.llvm_bin/'llvm-objcopy.exe'),'-O','binary',str(elf),str(binary)],check=True)
    data=binary.read_bytes()
    if len(data)>0x1d000: raise SystemExit('Firmware exceeds reserved memory')
    data+=bytes((-len(data))%4)
    words=struct.unpack('<'+'I'*(len(data)//4),data)
    destination=ROOT/'src/fpga/core/native_disc/firmware.mif'
    text=['DEPTH = 32768;','WIDTH = 32;','ADDRESS_RADIX = HEX;','DATA_RADIX = HEX;','CONTENT BEGIN']
    text += [f'{i:04X} : {word:08X};' for i,word in enumerate(words)]
    text += [f'[{len(words):04X}..7FFF] : 00000000;','END;']
    destination.write_text('\n'.join(text)+'\n')
    print(f'Built CUE/BIN firmware: {len(data):,} bytes; {destination.relative_to(ROOT)}')
if __name__=='__main__': main()
