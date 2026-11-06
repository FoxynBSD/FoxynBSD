/* The filesystem path and shm_open(3) must name the same object. */
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int
check_path(void)
{
	char name[64], path[80], byte;
	struct stat a, b;
	int shared = -1, pathfd = -1, ok = 0;

	snprintf(name, sizeof(name), "/foxyn-shm-test-%ld", (long)getpid());
	snprintf(path, sizeof(path), "/dev/shm%s", name);
	shared = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
	if (shared < 0)
		goto done;
	pathfd = open(path, O_RDWR);
	if (pathfd < 0 || fstat(shared, &a) != 0 || fstat(pathfd, &b) != 0)
		goto done;
	if (a.st_dev != b.st_dev || a.st_ino != b.st_ino) {
		errno = EINVAL;
		goto done;
	}
	if (write(shared, "x", 1) != 1 || read(pathfd, &byte, 1) != 1)
		goto done;
	if (byte != 'x') {
		errno = EIO;
		goto done;
	}
	ok = 1;
done:
	if (!ok)
		printf("rt-shmpath: FAIL shared-memory alias: %s\n", strerror(errno));
	if (pathfd >= 0)
		close(pathfd);
	if (shared >= 0) {
		close(shared);
		if (shm_unlink(name) != 0) {
			printf("rt-shmpath: FAIL shm_unlink: %s\n", strerror(errno));
			ok = 0;
		}
	}
	return ok;
}

int
main(void)
{
	struct passwd *pw;
	pid_t child;
	int status;

	if (!check_path())
		return 1;
	if (geteuid() == 0) {
		pw = getpwnam("nobody");
		if (pw == NULL) {
			puts("rt-shmpath: FAIL no nobody account");
			return 1;
		}
		child = fork();
		if (child == 0) {
			if (setgroups(0, NULL) != 0 || setgid(pw->pw_gid) != 0 ||
			    setuid(pw->pw_uid) != 0)
				_exit(1);
			_exit(check_path() ? 0 : 1);
		}
		if (child < 0 || waitpid(child, &status, 0) != child ||
		    !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
			puts("rt-shmpath: FAIL unprivileged access");
			return 1;
		}
	}
	puts("rt-shmpath: ok");
	return 0;
}
