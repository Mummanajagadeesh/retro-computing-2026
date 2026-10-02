/* w_file_blob.c -- replaces doomgeneric's w_file_stdc.c.
 *
 * Exports the class as `stdc_wad_file` because w_file.c's W_OpenFile()
 * calls stdc_wad_file.OpenFile(path) directly rather than walking the class
 * table -- so the symbol name is the integration point.
 *
 * There is no filesystem here. The IWAD is loaded into dmem by the testbench
 * ($fread into the data memory array) and bracketed by the linker symbols
 * _wad_start / _wad_end. This provides the same wad_file_t interface DOOM
 * expects, backed by that blob.
 *
 * Why patch this file rather than interpose fopen/fread: picolibc's stdio has
 * no backend on this target, so stdout/stderr/FILE do not link at all.
 * Overriding fopen would still leave every other stdio reference undefined.
 * Removing the stdio dependency from the one file that needs it is smaller
 * and cannot silently break picolibc internals.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "doomtype.h"
#include "m_misc.h"
#include "w_file.h"
#include "z_zone.h"
#include "wad_size.h"

extern char _wad_start[];
extern char _wad_end[];

extern wad_file_class_t stdc_wad_file;

typedef struct
{
    wad_file_t  wad;
    const byte *base;
    size_t      len;
} blob_wad_file_t;

static wad_file_t *W_BLOB_OpenFile(char *path)
{
    blob_wad_file_t *result;

    result = Z_Malloc(sizeof(*result), PU_STATIC, 0);
    result->base = (const byte *)_wad_start;

    /* _wad_end - _wad_start is the RESERVED region, which is larger than the
     * file. Using it as the length makes W_Read() succeed past the end of the
     * WAD, and more importantly it is the length the rest of DOOM reasons
     * about. Use the true file size, passed in by doom/build.sh. */
    result->len = (size_t)WAD_BLOB_SIZE;

    if ((size_t)(_wad_end - _wad_start) < result->len) {
        printf("[wad] FATAL: reserved region (%u B) smaller than the WAD (%u B)\n",
               (unsigned)(_wad_end - _wad_start), (unsigned)result->len);
        return NULL;
    }
    if (result->len < 12) {
        printf("[wad] FATAL: WAD blob is empty -- the testbench did not load it\n");
        return NULL;
    }

    result->wad.file_class = &stdc_wad_file;
    /* Leave mapped NULL: W_Read() below does the copy. Setting mapped would
     * make W_CacheLumpNum hand out pointers straight into the WAD, which is
     * faster but means Z_Free on a lump would be wrong. Copy is the safe
     * default and matches what w_file_stdc.c does. */
    result->wad.mapped     = NULL;
    result->wad.length     = (unsigned int)result->len;

    printf("[wad] %s -> blob at %p, %u bytes\n",
           path, (void *)result->base, (unsigned)result->len);

    return &result->wad;
}

static void W_BLOB_CloseFile(wad_file_t *wad)
{
    blob_wad_file_t *blob = (blob_wad_file_t *)wad;
    Z_Free(blob);
}

static size_t W_BLOB_Read(wad_file_t *wad, unsigned int offset,
                          void *buffer, size_t buffer_len)
{
    blob_wad_file_t *blob = (blob_wad_file_t *)wad;
    size_t avail, got;

    if (offset >= blob->len)
        return 0;

    avail = blob->len - offset;
    got = buffer_len < avail ? buffer_len : avail;

    memcpy(buffer, blob->base + offset, got);
    return got;
}

wad_file_class_t stdc_wad_file =
{
    W_BLOB_OpenFile,
    W_BLOB_CloseFile,
    W_BLOB_Read,
};
