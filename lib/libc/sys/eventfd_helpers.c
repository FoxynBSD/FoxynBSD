#include <sys/eventfd.h>
#include <unistd.h>

int
eventfd_read(int fd, eventfd_t *value)
{
	return read(fd, value, sizeof(*value)) == sizeof(*value) ? 0 : -1;
}

int
eventfd_write(int fd, eventfd_t value)
{
	return write(fd, &value, sizeof(value)) == sizeof(value) ? 0 : -1;
}
