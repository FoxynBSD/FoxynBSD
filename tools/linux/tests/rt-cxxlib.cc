/*
 * Shared library half of the C++ runtime check (see rt-cxx.cc): a static
 * object with a constructor and destructor (run from crtbegin.o's
 * .init_array/.fini_array handling and __cxa_atexit with this library's
 * __dso_handle), and a function that throws across the library boundary.
 */
#include <cstdio>
#include <stdexcept>

extern "C" int rt_lib_ctor_ran;
int rt_lib_ctor_ran;

namespace {
struct libobj {
	libobj() { rt_lib_ctor_ran = 1; }
	~libobj() { std::printf("rt-cxx: library destructor ran\n"); }
} the_libobj;
}

void
rt_lib_throw(int v)
{
	throw std::out_of_range(v > 0 ? "positive" : "other");
}
