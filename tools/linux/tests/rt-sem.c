/*
 * Named semaphores (libc's thr_sem.c): sem_open(3) with a name that
 * starts with a slash and, as software written for Linux uses them (JACK:
 * "jack_sem.0_default_system", O_CREAT | O_RDWR), one that does not and
 * an access mode in the flags.  A second sem_open(3) of the same name
 * must reach the same semaphore: sem_post(3) through one is seen by
 * sem_trywait(3) through the other.
 */
#include <errno.h>
#include <fcntl.h>
#include <semaphore.h>
#include <stdio.h>
#include <string.h>

static int
check(const char *name, int oflag)
{
	sem_t *a, *b;
	int ok;

	sem_unlink(name);
	a = sem_open(name, oflag, 0600, 0);
	if (a == SEM_FAILED) {
		printf("rt-sem: FAIL sem_open(\"%s\", 0x%x): %s\n", name,
		    oflag, strerror(errno));
		return (0);
	}
	b = sem_open(name, 0);
	if (b == SEM_FAILED) {
		printf("rt-sem: FAIL second sem_open(\"%s\"): %s\n", name,
		    strerror(errno));
		sem_close(a);
		sem_unlink(name);
		return (0);
	}
	ok = sem_post(a) == 0 && sem_trywait(b) == 0 &&
	    sem_trywait(b) == -1 && errno == EAGAIN;
	if (!ok)
		printf("rt-sem: FAIL \"%s\": post/trywait across opens\n", name);
	sem_close(b);
	sem_close(a);
	if (sem_unlink(name) != 0) {
		printf("rt-sem: FAIL sem_unlink(\"%s\"): %s\n", name,
		    strerror(errno));
		ok = 0;
	}
	return (ok);
}

int
main(void)
{
	int ok;

	ok = check("/rt_sem_slash", O_CREAT);
	ok = check("rt_sem_noslash", O_CREAT | O_RDWR) && ok;
	if (!ok)
		return (1);
	printf("rt-sem: ok\n");
	return (0);
}
