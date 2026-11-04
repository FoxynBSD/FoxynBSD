/*
 * Dynamic loading check: dlopen(3) a module with a constructor, call into
 * it, dlclose(3) it and see its destructor run.  The module is
 * rt-dlmod.c, installed as /root/tests/rt-dlmod.so.
 */
#include <dlfcn.h>
#include <stdio.h>

int rt_dl_state;	/* set by the module's constructor and destructor */

int
main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/root/tests/rt-dlmod.so";
	int (*fn)(int);
	void *h;

	h = dlopen(path, RTLD_NOW);
	if (h == NULL) {
		printf("rt-dlopen: FAIL dlopen: %s\n", dlerror());
		return (1);
	}
	if (rt_dl_state != 1) {
		printf("rt-dlopen: FAIL module constructor did not run\n");
		return (1);
	}
	fn = (int (*)(int))dlsym(h, "rt_dl_twice");
	if (fn == NULL || fn(21) != 42) {
		printf("rt-dlopen: FAIL dlsym/call\n");
		return (1);
	}
	dlclose(h);
	if (rt_dl_state != 2) {
		printf("rt-dlopen: FAIL module destructor did not run\n");
		return (1);
	}
	printf("rt-dlopen: ok\n");
	return (0);
}
