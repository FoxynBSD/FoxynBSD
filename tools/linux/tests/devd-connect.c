/* Check that devd's published sockets accept connections. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int
check_socket(const char *path, int type)
{
	struct sockaddr_un addr;
	int fd, result;

	fd = socket(AF_UNIX, type, 0);
	if (fd < 0) {
		perror("devd-connect: socket");
		return 1;
	}
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
	addr.sun_len = SUN_LEN(&addr);
	result = connect(fd, (struct sockaddr *)&addr, addr.sun_len);
	if (result < 0)
		perror(path);
	close(fd);
	return result < 0;
}

int
main(void)
{
	int result;

	result = check_socket("/var/run/devd.pipe", SOCK_STREAM);
	result |= check_socket("/var/run/devd.seqpacket.pipe", SOCK_SEQPACKET);
	return result;
}
