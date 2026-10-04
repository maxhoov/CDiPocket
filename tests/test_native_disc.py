"""Test the actual freestanding C parser and sector generator, using synthetic media."""
import ctypes as C
from pathlib import Path
import os
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]
class Track(C.Structure):
    _fields_=[(name,C.c_uint32) for name in ('file','mode','index0','index1','pregap','start','index1_absolute','end')]+[(name,C.c_uint8) for name in ('control','has_index0','has_index1','has_pregap')]
class BinFile(C.Structure):
    _fields_=[('path',C.c_char*256),('sectors',C.c_uint32)]
class Disc(C.Structure):
    _fields_=[('tracks',Track*99),('files',BinFile*99),('track_count',C.c_uint32),('file_count',C.c_uint32),('leadout',C.c_uint32)]
SIZE=C.CFUNCTYPE(C.c_uint32,C.c_char_p)
READ=C.CFUNCTYPE(C.c_uint32,C.c_char_p,C.c_uint32,C.c_void_p,C.c_uint32)

def bcd(n): return n//10*16+n%10
def msf(n):
    m,n=divmod(n,4500);s,f=divmod(n,75)
    return bytes((bcd(m),bcd(s),bcd(f)))
def crc(q):
    value=0
    for byte in q:
        value^=byte<<8
        for _ in range(8): value=((value<<1)^(0x1021 if value&0x8000 else 0))&0xffff
    return value^0xffff
def raw(lba,value=0x55):
    return b'\0'+b'\xff'*10+b'\0'+msf(lba)+b'\x02'+bytes((value,))*2336
def scramble(data):
    shift=1;result=bytearray(data)
    for i in range(12,2352):
        value=0
        for bit in range(8):
            value|=(shift&1)<<bit
            shift=(shift>>1)|(((shift^(shift>>1))&1)<<14)
        result[i]^=value
    return bytes(result)

class NativeDiscTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        output=ROOT/'build/disc_firmware'
        output.mkdir(parents=True,exist_ok=True)
        cls.dll_path=output/'disc_test.dll'
        compiler=Path(os.environ.get('DISC_FIRMWARE_LLVM_BIN','D:/Development/LLVM-23.1.1/bin'))/'clang.exe'
        subprocess.run([str(compiler),'-shared','-nostdlib',
            '-ffreestanding','-fno-builtin','-fno-stack-protector','-fuse-ld=lld',
            '-DHOST_TEST','-O2','-Wl,/noentry','-Wl,/export:disc_parse','-Wl,/export:disc_sector',
            str(ROOT/'firmware/native_disc/disc.c'),'-o',str(cls.dll_path)],check=True,capture_output=True)
        cls.lib=C.CDLL(str(cls.dll_path))
        cls.lib.disc_parse.argtypes=[C.POINTER(Disc),C.c_void_p,C.c_uint32,C.c_char_p,SIZE]
        cls.lib.disc_parse.restype=C.c_uint32
        cls.lib.disc_sector.argtypes=[C.POINTER(Disc),C.c_uint32,C.c_void_p,READ]
        cls.lib.disc_sector.restype=C.c_uint32
    def parse(self,text,files,path=b'/Assets/cdi/common/Game/Game.cue'):
        self.files=files
        self.size_callback=SIZE(lambda p:len(files.get(p.decode(),b'')))
        self.read_callback=READ(self.read)
        cue=C.create_string_buffer(text)
        disc=Disc()
        result=self.lib.disc_parse(C.byref(disc),cue,len(text),path,self.size_callback)
        return result,disc
    def read(self,path,offset,destination,length):
        data=self.files.get(path.decode(),b'')[offset:offset+length]
        if len(data)!=length: return 2
        C.memmove(destination,data,length);return 0
    def sector(self,disc,lba):
        buffer=C.create_string_buffer(2568)
        error=self.lib.disc_sector(C.byref(disc),lba,buffer,self.read_callback)
        return error,buffer.raw
    def check_q(self,record):
        q=record[2353:2376:2]
        self.assertEqual(record[2352:2376:2],bytes(12))
        self.assertEqual(q[10:],crc(q[:10]).to_bytes(2,'big'))
        self.assertEqual(record[2376:],bytes(192))
        return q
    def test_single_bin_toc_raw_and_q_crc(self):
        text=b'FILE "disc.bin" BINARY\n TRACK 01 MODE2/2352\n INDEX 01 00:00:00\n'
        image=raw(150)+raw(151,0x66)
        error,disc=self.parse(text,{'/Assets/cdi/common/Game/disc.bin':image})
        self.assertEqual(error,0);self.assertEqual(disc.leadout,152)
        error,record=self.sector(disc,0xffff0000)
        self.assertEqual(error,0)
        q=self.check_q(record);self.assertEqual(q[:3],b'\x41\x00\xa0');self.assertEqual(q[7:10],b'\x01\x10\x00')
        error,record=self.sector(disc,150)
        self.assertEqual(error,0);self.assertEqual(record[:2352],image[:2352])
        self.assertEqual(self.check_q(record)[:10],b'\x41\x01\x01'+bytes(4)+msf(150))
        error,record=self.sector(disc,152)
        self.assertEqual(error,0);self.assertEqual(self.check_q(record)[1],0xaa)
        self.assertEqual(self.sector(disc,280)[0],6)
    def test_cdi2352_native_cue_and_sector_equivalence(self):
        image=raw(150)+scramble(raw(151,0x66))
        files={"/Assets/cdi/common/Zelda's Adventure (Europe).bin":image}
        text=b'''CATALOG 0000000000000
FILE "Zelda's Adventure (Europe).bin" BINARY
  TRACK 01 CDI/2352
    INDEX 01 00:00:00
'''
        path=b"/Assets/cdi/common/Zelda's Adventure (Europe).cue"
        error,reference=self.parse(text.replace(b'CDI/2352',b'MODE2/2352'),files,path)
        self.assertEqual(error,0)
        for mode in (b'CDI/2352',b'cdi/2352'):
            error,disc=self.parse(text.replace(b'CDI/2352',mode),files,path)
            self.assertEqual(error,0);self.assertEqual(disc.tracks[0].mode,2)
            self.assertEqual(disc.tracks[0].control,0x41)
            for lba in (0xffff0000,0xffff0001,0xffff0002,150,151,152):
                self.assertEqual(self.sector(disc,lba),self.sector(reference,lba))
                self.check_q(self.sector(disc,lba)[1])
        for mode in (b'CDI/2336',b'CDI/2048'):
            self.assertEqual(self.parse(text.replace(b'CDI/2352',mode),files,path)[0],2)

    def test_shared_bin_and_multiple_bin_with_pregap(self):
        text=b'''FILE "mixed.bin" BINARY
TRACK 01 MODE2/2352
INDEX 01 00:00:00
TRACK 02 AUDIO
INDEX 00 00:00:01
INDEX 01 00:00:02
FILE "extra.bin" BINARY
TRACK 03 AUDIO
PREGAP 00:00:02
INDEX 01 00:00:00
'''
        error,disc=self.parse(text,{'/Assets/cdi/common/Game/mixed.bin':raw(150)+bytes([0x22])*2352*3,
            '/Assets/cdi/common/Game/extra.bin':bytes([0x33])*2352*2})
        self.assertEqual(error,0);self.assertEqual(disc.file_count,2)
        self.assertEqual([disc.tracks[i].index1_absolute for i in range(3)],[150,152,156])
        self.assertEqual(self.check_q(self.sector(disc,151)[1])[1:6],b'\x02\x00\x00\x00\x01')
        self.assertEqual(self.sector(disc,154)[1][:2352],bytes(2352))
        self.assertEqual(self.sector(disc,156)[1][:2352],bytes([0x33])*2352)
    def test_scrambled_data_and_audio_endianness(self):
        text=b'FILE "x.bin" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\n'
        original=raw(150)
        error,disc=self.parse(text,{'/Assets/cdi/common/Game/x.bin':scramble(original)})
        self.assertEqual(error,0);self.assertEqual(self.sector(disc,150)[1][:2352],original)
        pcm=bytes((0x34,0x12,0xbc,0xda))*588
        text=text.replace(b'MODE2/2352',b'AUDIO')
        error,disc=self.parse(text,{'/Assets/cdi/common/Game/x.bin':pcm})
        self.assertEqual(error,0);self.assertEqual(self.sector(disc,150)[1][:2352],pcm)
    def test_paths_utf8_quotes_crlf_metadata_and_flags(self):
        text=('\ufeffrem long metadata ignored\r\nfile "../音 轨.bin" binary\r\n'
              'track 01 audio\r\nFLAGS PRE DCP\r\nindex 01 00:00:00\r\n').encode()
        error,disc=self.parse(text,{'/Assets/cdi/common/音 轨.bin':bytes(2352)})
        self.assertEqual(error,0);self.assertEqual(disc.tracks[0].control,0x31)
        self.assertEqual(disc.files[0].path.decode(),'/Assets/cdi/common/音 轨.bin')
    def test_99_bin_tracks_no_apf_slot_limit(self):
        text='';files={}
        for i in range(1,100):
            text+=f'FILE "Track {i:02d}.bin" BINARY\nTRACK {i:02d} AUDIO\nINDEX 01 00:00:00\n'
            files[f'/Assets/cdi/common/Game/Track {i:02d}.bin']=bytes((i,))*2352
        error,disc=self.parse(text.encode(),files)
        self.assertEqual(error,0);self.assertEqual(disc.track_count,99);self.assertEqual(disc.file_count,99)
        error,record=self.sector(disc,248)
        self.assertEqual(error,0);self.assertEqual(record[:2352],bytes((99,))*2352)
        self.assertEqual(self.check_q(record)[1],0x99)
    def test_reject_bad_media_and_report_read_error(self):
        base=b'FILE "x.bin" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n'
        for text,media,expected in ((base,{},4),(base,{'/Assets/cdi/common/Game/x.bin':b'x'},5),
            (base.replace(b'AUDIO',b'MODE1/2048'),{'/Assets/cdi/common/Game/x.bin':bytes(2352)},2),
            (base.replace(b'BINARY',b'WAVE'),{},2),
            (base.replace(b'INDEX 01 00:00:00',b'INDEX 01 00:00:75'),{'/Assets/cdi/common/Game/x.bin':bytes(2352)},1),
            (base.replace(b'INDEX 01 00:00:00',b''),{'/Assets/cdi/common/Game/x.bin':bytes(2352)},5),
            (base.replace(b'TRACK 01',b'TRACK 02'),{'/Assets/cdi/common/Game/x.bin':bytes(2352)},5)):
            self.assertEqual(self.parse(text,media)[0],expected)
        error,disc=self.parse(base,{'/Assets/cdi/common/Game/x.bin':bytes(2352)})
        self.assertEqual(error,0);self.files.clear()
        self.assertEqual(self.sector(disc,150)[0],4)
if __name__=='__main__': unittest.main()
