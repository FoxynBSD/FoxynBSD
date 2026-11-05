/* eventfd(2): a counter shared across processes (SCM_RIGHTS), readiness, semaphore mode, limits. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/eventfd.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __DragonFly__
#include <sys/event.h>
#endif

#define CHECK(x) do { if (!(x)) { \
	fprintf(stderr, "rt-eventfd: line %d: %s (errno %d)\n", \
	    __LINE__, #x, errno); exit(1); } } while (0)

static void
send_fd(int sock, int fd)
{
	char byte = 'f';
	struct iovec iov = { &byte, 1 };
	union { struct cmsghdr align; char buf[CMSG_SPACE(sizeof(int))]; } control;
	struct msghdr msg;
	struct cmsghdr *cmsg;

	memset(&msg, 0, sizeof(msg));
	memset(&control, 0, sizeof(control));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = control.buf;
	msg.msg_controllen = sizeof(control.buf);
	cmsg = CMSG_FIRSTHDR(&msg);
	cmsg->cmsg_level = SOL_SOCKET;
	cmsg->cmsg_type = SCM_RIGHTS;
	cmsg->cmsg_len = CMSG_LEN(sizeof(fd));
	memcpy(CMSG_DATA(cmsg), &fd, sizeof(fd));
	CHECK(sendmsg(sock, &msg, 0) == 1);
}

static int
receive_fd(int sock)
{
	char byte;
	int fd;
	struct iovec iov = { &byte, 1 };
	union { struct cmsghdr align; char buf[CMSG_SPACE(sizeof(int))]; } control;
	struct msghdr msg;
	struct cmsghdr *cmsg;

	memset(&msg, 0, sizeof(msg));
	memset(&control, 0, sizeof(control));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = control.buf;
	msg.msg_controllen = sizeof(control.buf);
	CHECK(recvmsg(sock, &msg, 0) == 1);
	CHECK((msg.msg_flags & MSG_CTRUNC) == 0);
	cmsg = CMSG_FIRSTHDR(&msg);
	CHECK(cmsg != NULL && cmsg->cmsg_level == SOL_SOCKET &&
	    cmsg->cmsg_type == SCM_RIGHTS && cmsg->cmsg_len == CMSG_LEN(sizeof(fd)));
	memcpy(&fd, CMSG_DATA(cmsg), sizeof(fd));
	return fd;
}

static void
test_transfer(void)
{
	int sockets[2], fd, status;
	char byte;
	uint64_t value;
	pid_t child;
	struct pollfd pfd;

	fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	CHECK(fd >= 0);
	CHECK((fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0);
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
	child = fork();
	CHECK(child >= 0);
	if (child == 0) {
		close(sockets[0]);
		close(fd); /* Require the descriptor received over the socket. */
		fd = receive_fd(sockets[1]);
		value = 3;
		CHECK(write(fd, &value, sizeof(value)) == sizeof(value));
		CHECK(write(sockets[1], "a", 1) == 1);
		CHECK(read(sockets[1], &byte, 1) == 1 && byte == 'b');
		CHECK(read(fd, &value, sizeof(value)) == sizeof(value) && value == 2);
		close(fd);
		close(sockets[1]);
		_exit(0);
	}
	close(sockets[1]);
	pfd.fd = fd;
	pfd.events = POLLIN;
	CHECK(poll(&pfd, 1, 0) == 0);
	CHECK(read(fd, &value, sizeof(value)) == -1 && errno == EAGAIN);
	send_fd(sockets[0], fd);
	CHECK(read(sockets[0], &byte, 1) == 1 && byte == 'a');
	CHECK(poll(&pfd, 1, 0) == 1 && (pfd.revents & POLLIN));
	CHECK(read(fd, &value, sizeof(value)) == sizeof(value) && value == 3);
	CHECK(poll(&pfd, 1, 0) == 0);
	value = 2;
	CHECK(write(fd, &value, sizeof(value)) == sizeof(value));
	CHECK(write(sockets[0], "b", 1) == 1);
	CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) &&
	    WEXITSTATUS(status) == 0);
	close(sockets[0]);
	close(fd);
}

static void
test_boundaries(void)
{
	int fd;
	uint64_t value;
	struct pollfd pfd;
	volatile uintptr_t bad_address = 1;

	fd = eventfd(2, EFD_NONBLOCK | EFD_SEMAPHORE);
	CHECK(fd >= 0);
	CHECK(read(fd, &value, sizeof(value)) == sizeof(value) && value == 1);
	CHECK(read(fd, &value, sizeof(value)) == sizeof(value) && value == 1);
	CHECK(read(fd, &value, sizeof(value)) == -1 && errno == EAGAIN);
	close(fd);

	fd = eventfd(0, EFD_NONBLOCK);
	CHECK(fd >= 0);
	pfd.fd = fd;
	pfd.events = POLLOUT;
	CHECK(poll(&pfd, 1, 0) == 1 && (pfd.revents & POLLOUT));
	CHECK(write(fd, (const void *)bad_address, sizeof(value)) == -1 && errno == EFAULT);
	value = UINT64_MAX;
	CHECK(write(fd, &value, sizeof(value)) == -1 && errno == EINVAL);
	value = UINT64_MAX - 1;
	CHECK(write(fd, &value, sizeof(value)) == sizeof(value));
	CHECK(poll(&pfd, 1, 0) == 0);
	value = 1;
	CHECK(write(fd, &value, sizeof(value)) == -1 && errno == EAGAIN);
	CHECK(read(fd, &value, sizeof(value)) == sizeof(value) && value == UINT64_MAX - 1);
	CHECK(poll(&pfd, 1, 0) == 1 && (pfd.revents & POLLOUT));
	CHECK(write(fd, &value, sizeof(value) - 1) == -1 && errno == EINVAL);
	close(fd);
	fd = eventfd(1, EFD_NONBLOCK);
	CHECK(fd >= 0);
	CHECK(read(fd, (void *)bad_address, sizeof(value)) == -1 && errno == EFAULT);
	close(fd);
}

static void
test_concurrent_writers(void)
{
	int fd, i, j, status;
	pid_t children[4];
	uint64_t value = 1;

	fd = eventfd(0, 0);
	CHECK(fd >= 0);
	for (i = 0; i < 4; ++i) {
		children[i] = fork();
		CHECK(children[i] >= 0);
		if (children[i] == 0) {
			for (j = 0; j < 1000; ++j)
				CHECK(write(fd, &value, sizeof(value)) == sizeof(value));
			_exit(0);
		}
	}
	for (i = 0; i < 4; ++i)
		CHECK(waitpid(children[i], &status, 0) == children[i] &&
		    WIFEXITED(status) && WEXITSTATUS(status) == 0);
	CHECK(read(fd, &value, sizeof(value)) == sizeof(value) && value == 4000);
	close(fd);
}

/* A blocked reader wakes when another process writes (libc helpers). */
static void
test_blocking(void)
{
	int fd, status;
	pid_t child;
	eventfd_t value;

	fd = eventfd(0, 0);
	CHECK(fd >= 0);
	child = fork();
	CHECK(child >= 0);
	if (child == 0) {
		usleep(200000);
		CHECK(eventfd_write(fd, 5) == 0);
		_exit(0);
	}
	CHECK(eventfd_read(fd, &value) == 0 && value == 5);
	CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) &&
	    WEXITSTATUS(status) == 0);
	close(fd);
}

#ifdef __DragonFly__
static void
test_kqueue(void)
{
	int fd, kq;
	uint64_t value = 1;
	struct kevent change, event;
	struct timespec immediate = { 0, 0 };

	fd = eventfd(0, EFD_NONBLOCK);
	CHECK(fd >= 0);
	kq = kqueue();
	CHECK(kq >= 0);
	EV_SET(&change, fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
	CHECK(kevent(kq, &change, 1, NULL, 0, NULL) == 0);
	CHECK(kevent(kq, NULL, 0, &event, 1, &immediate) == 0);
	CHECK(write(fd, &value, sizeof(value)) == sizeof(value));
	CHECK(kevent(kq, NULL, 0, &event, 1, &immediate) == 1 &&
	    event.filter == EVFILT_READ && event.ident == (uintptr_t)fd);
	CHECK(read(fd, &value, sizeof(value)) == sizeof(value) && value == 1);
	CHECK(kevent(kq, NULL, 0, &event, 1, &immediate) == 0);
	close(kq);
	close(fd);
}
#endif

int
main(void)
{
	alarm(10); /* A broken IPC or wakeup must not hang the test runner. */
	test_transfer();
	test_boundaries();
	test_concurrent_writers();
	test_blocking();
#ifdef __DragonFly__
	test_kqueue();
#endif
	puts("rt-eventfd: ok");
	return 0;
}
