#ifndef CSQLCIPHER_SHIM_H
#define CSQLCIPHER_SHIM_H

// SQLCipher guards its key APIs behind this feature define. Expose the typed
// C functions so callers never need to interpolate secrets into PRAGMA SQL.
#ifndef SQLITE_HAS_CODEC
#define SQLITE_HAS_CODEC 1
#endif
#include <sqlite3.h>

#endif
