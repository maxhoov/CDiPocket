"""Synthetic CUE/BIN files and independently assembled expected sector records."""
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from test_native_disc import raw,scramble,msf,crc

def write_hex(path,data):
    path.write_text('\n'.join(f'{byte:02x}' for byte in data)+'\n')
def record(data,q):
    q+=crc(q).to_bytes(2,'big')
    return data+b''.join(bytes((0,v)) for v in q)+bytes(192)
def main():
    out=ROOT/'build/sim/fixtures'
    out.mkdir(parents=True,exist_ok=True)
    cue=b'''FILE "mixed data.bin" BINARY
TRACK 01 CDI/2352
INDEX 01 00:00:00
TRACK 02 AUDIO
INDEX 00 00:00:02
INDEX 01 00:00:03
FILE "extra.bin" BINARY
TRACK 03 AUDIO
PREGAP 00:00:02
INDEX 01 00:00:00
'''
    bin0=raw(150)+scramble(raw(151,0x66))+bytes((0x34,0x12,0xbc,0xda))*588*3
    bin1=bytes((0x78,0x56,0xf0,0xde))*588*2
    path=b'/Assets/cdi/common/Game/Game.cue\0'
    write_hex(out/'cue.hex',cue)
    write_hex(out/'bin0.hex',bin0)
    write_hex(out/'bin1.hex',bin1)
    write_hex(out/'path.hex',path+bytes(256-len(path)))
    zero=bytes(2352)
    samples=[
        (0xffff0000,zero,bytes((0x41,0,0xa0))+msf(0)+b'\0'+bytes((1,0x10,0))),
        (0xffff0001,zero,bytes((1,0,0xa1))+msf(1)+b'\0'+bytes((3,0,0))),
        (0xffff0002,zero,bytes((1,0,0xa2))+msf(2)+b'\0'+msf(159)),
        (0xffff0005,zero,bytes((1,0,3))+msf(5)+b'\0'+msf(157)),
        (0,zero,bytes((0x41,1,0))+msf(150)+b'\0'+msf(0)),
        (150,raw(150),bytes((0x41,1,1))+msf(0)+b'\0'+msf(150)),
        (151,raw(151,0x66),bytes((0x41,1,1))+msf(1)+b'\0'+msf(151)),
        (152,bin0[2*2352:3*2352],bytes((1,2,0))+msf(1)+b'\0'+msf(152)),
        (153,bin0[3*2352:4*2352],bytes((1,2,1))+msf(0)+b'\0'+msf(153)),
        (155,zero,bytes((1,3,0))+msf(2)+b'\0'+msf(155)),
        (157,bin1[:2352],bytes((1,3,1))+msf(0)+b'\0'+msf(157)),
        (158,bin1[2352:],bytes((1,3,1))+msf(1)+b'\0'+msf(158)),
        (159,zero,bytes((1,0xaa,1))+msf(0)+b'\0'+msf(159)),
    ]
    write_hex(out/'expected.hex',b''.join(record(data,q) for _,data,q in samples))
    (out/'params.svh').write_text(f'localparam CUE_LENGTH={len(cue)};\nlocalparam TEST_SECTORS={len(samples)};\n')
    (out/'lbas.hex').write_text('\n'.join(f'{lba:08x}' for lba,_,_ in samples)+'\n')
    print(f'Created synthetic native-disc fixture with {len(samples)} expected sectors.')
if __name__=='__main__':main()
