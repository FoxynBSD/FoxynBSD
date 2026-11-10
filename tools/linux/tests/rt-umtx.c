/* Exercise the user-address wait primitive needed by desktop runtimes. */
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

static int
fail(const char *what)
{
	perror(what);
	return 1;
}

int
main(void)
{
	volatile int *word;
	pid_t child;
	int p[2], status = -1, rc, i;
	char ready;

	word = mmap(NULL, sizeof(*word), PROT_READ | PROT_WRITE,
	    MAP_SHARED | MAP_ANON, -1, 0);
	if (word == MAP_FAILED)
		return fail("rt-umtx: mmap");
	*word = 0;
	errno = 0;
	if (umtx_sleep(word, 1, 10000) != -1 || errno != EBUSY) {
		fprintf(stderr, "rt-umtx: FAIL mismatch errno=%d\n", errno);
		return 1;
	}
	errno = 0;
	if (umtx_sleep(word, 0, -1) != -1 || errno != EINVAL) {
		fprintf(stderr, "rt-umtx: FAIL negative timeout errno=%d\n", errno);
		return 1;
	}
	/* Spurious wakes are allowed, so retry until a timed wait expires. */
	for (i = 0; i < 20; i++) {
		errno = 0;
		rc = umtx_sleep(word, 0, 10000);
		if (rc == -1 && errno == EWOULDBLOCK)
			break;
		if (rc == -1 && errno != EINTR)
			return fail("rt-umtx: timed wait");
	}
	if (i == 20) {
		fputs("rt-umtx: FAIL timed wait did not expire\n", stderr);
		return 1;
	}
	if (pipe(p) != 0)
		return fail("rt-umtx: pipe");
	child = fork();
	if (child < 0)
		return fail("rt-umtx: fork");
	if (child == 0) {
		close(p[0]);
		if (write(p[1], "r", 1) != 1)
			_exit(1);
		close(p[1]);
		while (__atomic_load_n(word, __ATOMIC_ACQUIRE) == 0) {
			rc = umtx_sleep(word, 0, 100000);
			if (rc == -1 && errno != EBUSY && errno != EWOULDBLOCK &&
			    errno != EINTR)
				_exit(2);
		}
		_exit(0);
	}
	close(p[1]);
	if (read(p[0], &ready, 1) != 1)
		return fail("rt-umtx: child readiness");
	close(p[0]);
	__atomic_store_n(word, 1, __ATOMIC_RELEASE);
	if (umtx_wakeup(word, 0) != 0)
		return fail("rt-umtx: wakeup");
	if (waitpid(child, &status, 0) != child || !WIFEXITED(status) ||
	    WEXITSTATUS(status) != 0) {
		fprintf(stderr, "rt-umtx: FAIL child status=%d\n", status);
		return 1;
	}
	munmap((void *)word, sizeof(*word));
	puts("rt-umtx: ok");
	return 0;
}
