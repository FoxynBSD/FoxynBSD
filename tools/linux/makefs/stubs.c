/*
 * makefs on a Linux host builds only the ffs back end (build.sh disk);
 * the others need more of the kernel's headers than a host has.
 */
#include <err.h>

#define STUB(fs)							\
void fs##_prep_opts(void *f) { (void)f; }				\
int fs##_parse_opts(const char *o, void *f)				\
{ (void)o; (void)f; errx(1, #fs ": not in this makefs (Linux host build)"); } \
void fs##_cleanup_opts(void *f) { (void)f; }				\
void fs##_makefs(const char *i, const char *d, void *r, void *f)	\
{ (void)i; (void)d; (void)r; (void)f;					\
  errx(1, #fs ": not in this makefs (Linux host build)"); }

STUB(cd9660)
STUB(msdos)
STUB(hammer2)
