/* menu_blob.h -- unified menu WAD layout (MENU_BUILD only).
 *
 * One blob carries everything the menu firmware needs, packed by
 * games/menu/mkmenuwad.py:
 *
 *   struct menuwad_hdr
 *   struct menuwad_rom[rom_count]     (chip-8 ROM table)
 *   ... disk.blob bytes (CP/M) ...
 *   ... doom1.wad bytes (DOOM) ...
 *   ... raw chip-8 ROM bytes ...
 *
 * Offsets are from the blob base (_wad_start). Payloads are 4-aligned.
 * The menu parses the header at boot and points each game at its data
 * through the globals below before launching it.
 */
#ifndef MENU_BLOB_H
#define MENU_BLOB_H

#include <stdint.h>

#define MENUWAD_MAGIC 0x31444157554E454DULL   /* "MENUWAD1" little-endian */
#define MENUWAD_VERSION 1

struct menuwad_hdr {
    uint64_t magic;
    uint16_t version;
    uint16_t rom_count;
    uint32_t disk_off, disk_len;
    uint32_t doom_off, doom_len;
    uint32_t reserved;      /* pad so sizeof == 32: the ROM table follows */
};

_Static_assert(sizeof(struct menuwad_hdr) == 32, "menuwad hdr layout");

struct menuwad_rom {
    char name[12];
    uint32_t off, len;
};

_Static_assert(sizeof(struct menuwad_rom) == 20, "menuwad rom layout");

/* Selection globals, set by menu.c before launching a game. */
extern const uint8_t *menu_disk_base;   /* disk.blob image for CP/M */
extern const uint8_t *menu_doom_base;   /* doom1.wad image for DOOM */
extern const uint8_t *menu_rom_ptr;    /* selected chip-8 ROM bytes */
extern uint32_t menu_rom_len;          /* selected chip-8 ROM length */

#endif
