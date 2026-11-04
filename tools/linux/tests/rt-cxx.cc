/*
 * C++ runtime check, dynamically linked against libstdc++.so and the
 * test library librtcxx.so (rt-cxxlib.cc):
 *  - static constructors of the program and of the library ran;
 *  - an exception thrown in the library unwinds through a frame with a
 *    destructor in the program and is caught by its type (libgcc_pic's
 *    unwinder, .eh_frame_hdr lookup across objects);
 *  - destructors and atexit handlers run at exit, in reverse order (the
 *    library's destructor prints after the program's).
 */
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

extern "C" int rt_lib_ctor_ran;
void rt_lib_throw(int);

static int prog_ctor_ran, unwound;

namespace {
struct progobj {
	progobj() { prog_ctor_ran = 1; }
	~progobj() { std::printf("rt-cxx: program destructor ran\n"); }
} the_progobj;

struct guard {
	~guard() { unwound++; }
};
}

static void __attribute__((noinline))
middle(int v)
{
	guard g;
	rt_lib_throw(v);
}

static void
at_exit(void)
{
	std::printf("rt-cxx: atexit handler ran\n");
}

int
main()
{
	int ok = 1;

	std::atexit(at_exit);
	if (!prog_ctor_ran || !rt_lib_ctor_ran) {
		std::printf("rt-cxx: FAIL constructors (program %d, library %d)\n",
		    prog_ctor_ran, rt_lib_ctor_ran);
		ok = 0;
	}
	try {
		middle(1);
		std::printf("rt-cxx: FAIL nothing was thrown\n");
		ok = 0;
	} catch (const std::out_of_range &e) {
		if (unwound != 1) {
			std::printf("rt-cxx: FAIL destructor ran %d times\n", unwound);
			ok = 0;
		}
	} catch (...) {
		std::printf("rt-cxx: FAIL caught by the wrong handler\n");
		ok = 0;
	}
	if (ok)
		std::printf("rt-cxx: ok\n");
	return (ok ? 0 : 1);
}
