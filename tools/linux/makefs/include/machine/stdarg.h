/* makefs on a Linux host: <sys/sbuf.h> wants the BSD names of <stdarg.h>. */
#include <stdarg.h>
typedef va_list __va_list;
#define __va_start(ap, last)	va_start(ap, last)
#define __va_end(ap)		va_end(ap)
