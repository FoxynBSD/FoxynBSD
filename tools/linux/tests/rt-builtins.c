/*
 * Compiler runtime check (lib/libcompiler_rt): operations that clang
 * lowers to libgcc/compiler-rt library calls on x86_64, with known
 * results.  Built static and dynamic by build.sh rootfs and run at boot.
 * The volatile operands keep clang from folding the calls away.
 */
#include <stdio.h>

static int failed;

static void
check(const char *what, int ok)
{
	if (!ok) {
		printf("rt-builtins: FAIL %s\n", what);
		failed++;
	}
}

int
main(void)
{
	volatile __int128 a = (__int128)1 << 100, b = 12345;
	volatile unsigned __int128 ua = ~(unsigned __int128)0;
	volatile double d = 0x1p100;
	volatile long double ld = 123456789.0L;
	volatile float f = 1.5f;
	volatile _Float16 h;
	volatile long long x = 1LL << 62;
	long long ov;
	__int128 q, r;

	q = a / b;			/* __divti3 */
	r = a % b;			/* __modti3 */
	check("__divti3/__modti3", q * b + r == a && r >= 0 && r < b);
	check("unsigned 128-bit division", ua / 3 == ~(unsigned __int128)0 / 3 &&
	    (ua / 3) * 3 == ua);
	check("__fixdfti", (__int128)d == a);
	check("__floattidf", (double)a == 1267650600228229401496703205376.0);
	check("int128 to long double", (long double)(__int128)ld == 123456789.0L);
	check("__fixxfti", (__int128)ld == 123456789);
	h = f;				/* __truncsfhf2 */
	check("__extendhfsf2", (float)h == 1.5f);
	check("mul_overflow", __builtin_mul_overflow(x, 4LL, &ov) == 1);
	check("popcount",
	    __builtin_popcountll((unsigned long long)(ua >> 64)) == 64);
	if (failed == 0)
		printf("rt-builtins: ok\n");
	return (failed != 0);
}
