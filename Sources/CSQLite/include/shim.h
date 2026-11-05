/* One header so SwiftPM can expose the system sqlite3 on every platform.
   macOS ships it in the SDK; Linux needs libsqlite3-dev; Windows needs
   sqlite3 on the include/lib path. */
#include <sqlite3.h>
