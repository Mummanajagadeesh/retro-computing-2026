#!/usr/bin/env python3
"""PC side of the DE0-Nano DOOM flow: inspect the ELF, upload ELF + WAD to
the FPGA bootloader over serial, verify CRC, boot, then show the console
transcript (typed keys go to the game as taps).

Needs only pyserial:  pip install pyserial
No ELF tools needed: the parser below is hand-rolled (ELF32).

Protocol (see fpga/rtl/mem_top_fpga.v bootloader):
  PC  -> FPGA : b'HELLO' (retried 1/s until answered)
  FPGA -> PC   : b'BLRDY1'
  PC  -> FPGA : u16 nseg, then per segment u32 addr, u32 len, <len bytes>
                (lengths padded to 4 by the sender)
  PC  -> FPGA : u32 wad_addr, u32 wad_len, <wad bytes>
  FPGA -> PC   : b'.' after every 4 KB received
  PC  -> FPGA : b'GO' + u32 crc32 of all payload bytes in send order
  FPGA -> PC   : b'OK' + u32 crc (match: core boots) or b'BAD'
After OK the port carries the transcript (FPGA -> PC, raw bytes) and
key taps (PC -> FPGA, one byte each).
"""
import argparse
import struct
import sys
import time
import zlib
import serial

SDRAM_BYTES = 64 * 1024 * 1024
FB_RESERVE_LO = SDRAM_BYTES - 64 * 1024   # top 64 KB holds the framebuffer
ACK_EVERY = 4096


def parse_elf(path):
    """Return (loads, wad_addr). loads = [(paddr, bytes)] zero-padded to
    memsz and then to a 4 multiple. wad_addr from the _wad_start symbol."""
    img = open(path, 'rb').read()
    if img[:4] != b'\x7fELF' or img[4] != 1:
        raise SystemExit('not a 32-bit ELF: ' + path)
    e_phoff, e_shoff = struct.unpack_from('<II', img, 0x1C)
    e_phentsize, e_phnum = struct.unpack_from('<HH', img, 0x2A)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', img, 0x2E)
    loads = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz = \
            struct.unpack_from('<IIIIII', img, o)[:6]
        if p_type != 1 or p_memsz == 0:   # PT_LOAD only
            continue
        data = img[p_offset:p_offset + p_filesz]
        data += b'\x00' * (p_memsz - p_filesz)
        data += b'\x00' * (-len(data) % 4)
        loads.append((p_paddr, data))
    wad_addr = None
    if e_shnum and e_shoff:
        shstr = struct.unpack_from('<I', img,
                                   e_shoff + e_shstrndx * e_shentsize + 16)[0]
        symtab = strtab = None
        for i in range(e_shnum):
            o = e_shoff + i * e_shentsize
            _, sh_type, _, _, sh_offset, sh_size, sh_link = \
                struct.unpack_from('<IIIIIII', img, o)[:7]
            if sh_type == 2:   # SHT_SYMTAB
                symtab = (sh_offset, sh_size)
                stro = e_shoff + sh_link * e_shentsize
                strtab = struct.unpack_from('<I', img, stro + 16)[0]
        if symtab and strtab:
            off, size = symtab
            for o in range(off, off + size, 16):
                st_name, st_value = struct.unpack_from('<II', img, o)
                e = img.index(b'\x00', strtab + st_name)
                if img[strtab + st_name:e] == b'_wad_start':
                    wad_addr = st_value
                    break
    return loads, wad_addr


def check_ranges(loads, wad_addr, wad_len):
    probs = []
    for addr, data in loads:
        if addr + len(data) > SDRAM_BYTES:
            probs.append(f'segment @{addr:#x}+{len(data):#x} past 64 MB')
        if addr < FB_RESERVE_LO < addr + len(data):
            probs.append(f'segment @{addr:#x} overlaps fb reserve')
    if wad_addr is None:
        probs.append('no _wad_start symbol (use --wad-base)')
    elif wad_addr + wad_len > SDRAM_BYTES:
        probs.append('WAD past 64 MB')
    elif wad_addr < FB_RESERVE_LO < wad_addr + wad_len:
        probs.append('WAD overlaps fb reserve')
    return probs


def cmd_info(a):
    loads, wad_sym = parse_elf(a.elf)
    wad = open(a.wad, 'rb').read()
    if wad[:4] not in (b'IWAD', b'PWAD') and not a.wad.endswith('.ch8'):
        print(f'Note: {a.wad} is not an IWAD/PWAD (treating as raw ROM/blob)')
    wad_addr = a.wad_base if a.wad_base is not None else wad_sym
    total = sum(len(d) for _, d in loads) + len(wad)
    print(f'ELF: {a.elf}')
    for addr, data in loads:
        print(f'  load @{addr:#010x} len {len(data):#8x} ({len(data)/1024:.1f} KB)')
    print(f'WAD: {a.wad} ({len(wad)/1024/1024:.2f} MB) -> @{wad_addr:#010x}'
          + ('  [from --wad-base]' if a.wad_base is not None else ''))
    print(f'total upload {total/1024/1024:.2f} MB, '
          f'~{total*10/a.baud:.0f} s at {a.baud} baud')
    probs = check_ranges(loads, wad_addr, len(wad))
    for p in probs:
        print('PROBLEM:', p)
    if probs:
        raise SystemExit(1)
    print('layout OK: everything inside 64 MB, clear of the fb reserve')


def open_port(a):
    ser = serial.Serial(a.port, a.baud, timeout=5)
    ser.reset_input_buffer()
    return ser


def read_ack(ser, sent_payload):
    """Read one '.' ack, skipping any stale beacon bytes from BLRDY1."""
    stale_count = 0
    while True:
        ack = ser.read(1)
        if ack == b'.':
            return
        if ack in b'BLRDY1':
            stale_count += 1
            if stale_count > 50:
                raise SystemExit(
                    'board keeps beaconing BLRDY1 instead of acking: it '
                    'never received the upload. Check the TX wire (JP1 '
                    'pin 2 -> TTL module TX pin), press KEY1, retry.')
            continue
        if ack == b'':
            raise SystemExit(
                f'lost ack at payload offset {sent_payload}: board silent. '
                'Check wiring (JP1 pin 2 -> TTL TX), press KEY1, retry.')
        raise SystemExit(
            f'lost ack at payload offset {sent_payload} (got {ack!r})')



def cmd_upload(a):
    loads, wad_sym = parse_elf(a.elf)
    wad = open(a.wad, 'rb').read()
    wad_addr = a.wad_base if a.wad_base is not None else wad_sym
    probs = check_ranges(loads, wad_addr, len(wad))
    if probs:
        raise SystemExit('PROBLEM: ' + probs[0])
    wad_pad = wad + b'\x00' * (-len(wad) % 4)
    payloads = [d for _, d in loads] + [wad_pad]
    crc = zlib.crc32(b''.join(payloads)) & 0xFFFFFFFF

    ser = open_port(a)
    print(f'{a.port} @ {a.baud}: waiting for bootloader (HELLO)...')
    found = False
    for _ in range(30):
        ser.reset_input_buffer()
        ser.write(b'HELLO')
        buf = b''
        deadline = time.time() + 5
        while time.time() < deadline:   # sliding match: a beacon and the
            chunk = ser.read(6)         # HELLO answer can arrive back to back
            if chunk:
                buf = (buf + chunk)[-11:]
                if b'BLRDY1' in buf:
                    found = True
                    break
        if found:
            break
        time.sleep(1)
    if not found:
        raise SystemExit('no bootloader answer (is the bitstream running?)')
    # A stale second BLRDY1 (beacon caught above + the real HELLO answer)
    # may still be in flight; nothing else can be, so drain it all away.
    ser.reset_input_buffer()
    time.sleep(0.3)
    ser.reset_input_buffer()
    print('bootloader ready, sending...')

    t0 = time.time()
    total_payload = sum(len(d) for _, d in loads) + len(wad_pad)
    sent_payload = 0

    ser.write(struct.pack('<H', len(loads)))
    all_segs = list(loads) + [(wad_addr, wad_pad)]
    for addr, data in all_segs:
        ser.write(struct.pack('<II', addr, len(data)))
        data_off = 0
        while data_off < len(data):
            rem_to_dot = ACK_EVERY - (sent_payload % ACK_EVERY)
            chunk_size = min(len(data) - data_off, rem_to_dot)
            ser.write(data[data_off:data_off + chunk_size])
            data_off += chunk_size
            sent_payload += chunk_size
            if sent_payload % ACK_EVERY == 0:
                read_ack(ser, sent_payload)
                print(f'\r  {sent_payload*100//total_payload}% ({sent_payload/1024:.0f}/{total_payload/1024:.0f} KB)',
                      end='', flush=True)
    print()
    ser.write(b'GO' + struct.pack('<I', crc))
    resp = ser.read(2)
    if resp == b'RNG':
        raise SystemExit('bootloader rejected an address range')
    if resp != b'OK':
        raise SystemExit(f'upload failed (resp={resp!r})')
    echo = struct.unpack('<I', ser.read(4))[0]
    dt = time.time() - t0
    print(f'CRC match ({echo:#010x}), {total_payload/1024/dt:.0f} KB/s: core booting')
    if getattr(a, 'no_term', False):
        ser.close()
        return
    terminal(ser)


def terminal(ser):
    print('--- transcript (type to tap keys, Ctrl-C quits) ---')
    try:
        import msvcrt

        def getkey():
            return msvcrt.getch() if msvcrt.kbhit() else None
    except ImportError:
        import select
        import termios
        import tty
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        tty.setcbreak(fd)

        def getkey():
            if select.select([sys.stdin], [], [], 0)[0]:
                return sys.stdin.buffer.read(1)
            return None
    try:
        ser.timeout = 0.05
        while True:
            b = ser.read(4096)
            if b:
                sys.stdout.buffer.write(b)
                sys.stdout.buffer.flush()
            k = getkey()
            if k:
                if k == b'\x03':
                    raise KeyboardInterrupt
                ser.write(k)
    except KeyboardInterrupt:
        print('\n--- quit ---')
    finally:
        try:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        except (NameError, UnboundLocalError):
            pass


def main():
    ap = argparse.ArgumentParser(description='DOOM FPGA uploader + terminal')
    ap.add_argument('--port', default='COM7')
    ap.add_argument('--baud', type=int, default=921600)
    ap.add_argument('--wad-base', type=lambda s: int(s, 0), default=None)
    sub = ap.add_subparsers(dest='cmd', required=True)
    i = sub.add_parser('info', help='show ELF/WAD layout vs 64 MB')
    i.add_argument('elf')
    i.add_argument('wad')
    u = sub.add_parser('upload', help='upload, verify, boot, terminal')
    u.add_argument('elf')
    u.add_argument('wad')
    u.add_argument('--no-term', action='store_true', help='exit after upload without entering terminal')
    t = sub.add_parser('term', help='transcript terminal only')
    a = ap.parse_args()
    if a.cmd == 'info':
        cmd_info(a)
    elif a.cmd == 'upload':
        cmd_upload(a)
    else:
        terminal(open_port(a))


if __name__ == '__main__':
    main()
