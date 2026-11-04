/* makefs on a Linux host: only the vnode types of <sys/vfscache.h>. */
#ifndef _SYS_VFSCACHE_H_
#define _SYS_VFSCACHE_H_
enum vtype	{ VNON, VREG, VDIR, VBLK, VCHR, VLNK, VSOCK, VFIFO, VBAD,
		  VDATABASE, VINT };
#endif
