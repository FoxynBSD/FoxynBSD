/* Module for rt-dlopen.c: reports its constructor and destructor. */
extern int rt_dl_state;

__attribute__((constructor)) static void
mod_init(void)
{
	rt_dl_state = 1;
}

__attribute__((destructor)) static void
mod_fini(void)
{
	rt_dl_state = 2;
}

int
rt_dl_twice(int v)
{
	return (2 * v);
}
