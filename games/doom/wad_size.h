/* Size of the IWAD blob the simulator loaded, in bytes.
 *
 * _wad_end - _wad_start is the RESERVED region (30 MB), not the file size,
 * and using it makes W_Init read the lump directory from the wrong offset --
 * it fails with "W_GetNumForName: PNAMES not found!". The real size is passed
 * in at build time by doom/build.sh, which stats the WAD file.
 */
#ifndef WAD_BLOB_SIZE
#error "build with -DWAD_BLOB_SIZE=<bytes> (see doom/build.sh)"
#endif
