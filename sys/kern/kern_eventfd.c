/* A transferable counter for event notification. */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/event.h>
#include <sys/eventfd.h>
#include <sys/file.h>
#include <sys/filedesc.h>
#include <sys/kernel.h>
#include <sys/lock.h>
#include <sys/malloc.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/sysmsg.h>
#include <sys/uio.h>
#include <sys/file2.h>

static MALLOC_DEFINE(M_EVENTFD, "eventfd", "event counters");
#define EVENTFD_MAX (~(uint64_t)0 - 1)

struct event_counter {
	struct lock lock;
	struct klist readers;
	struct klist writers;
	uint64_t value;
	int semaphore;
	int read_wait;
	int write_wait;
};

static int counter_read(struct file *, struct uio *, struct ucred *, int);
static int counter_write(struct file *, struct uio *, struct ucred *, int);
static int counter_filter(struct file *, struct knote *);
static int counter_stat(struct file *, struct stat *, struct ucred *);
static int counter_close(struct file *);
static void counter_detach(struct knote *);
static int counter_read_ready(struct knote *, long);
static int counter_write_ready(struct knote *, long);

static struct fileops counter_ops = {
	.fo_read = counter_read,
	.fo_write = counter_write,
	.fo_ioctl = badfo_ioctl,
	.fo_kqfilter = counter_filter,
	.fo_stat = counter_stat,
	.fo_close = counter_close,
	.fo_shutdown = nofo_shutdown,
	.fo_seek = badfo_seek
};
static struct filterops counter_read_filter =
    { FILTEROP_ISFD | FILTEROP_MPSAFE, NULL, counter_detach, counter_read_ready };
static struct filterops counter_write_filter =
    { FILTEROP_ISFD | FILTEROP_MPSAFE, NULL, counter_detach, counter_write_ready };

/* Copy through a private uio so an error cannot report a partial operation. */
static int
counter_copy(struct uio *uio, uint64_t *value)
{
	struct uio copy = *uio;
	struct iovec *iov;
	size_t size;
	int error;

	size = uio->uio_iovcnt * sizeof(*iov);
	iov = kmalloc(size, M_TEMP, M_WAITOK);
	bcopy(uio->uio_iov, iov, size);
	copy.uio_iov = iov;
	error = uiomove((caddr_t)value, sizeof(*value), &copy);
	kfree(iov, M_TEMP);
	return error;
}

static void
counter_advance(struct uio *uio)
{
	size_t left = sizeof(uint64_t), n;

	while (left != 0) {
		if (uio->uio_iov->iov_len == 0) {
			++uio->uio_iov;
			--uio->uio_iovcnt;
			continue;
		}
		n = uio->uio_iov->iov_len < left ? uio->uio_iov->iov_len : left;
		uio->uio_iov->iov_base = (char *)uio->uio_iov->iov_base + n;
		uio->uio_iov->iov_len -= n;
		uio->uio_resid -= n;
		uio->uio_offset += n;
		left -= n;
	}
}

static int
counter_nonblock(struct file *fp, int flags)
{
	if (flags & O_FBLOCKING)
		return 0;
	return (flags & O_FNONBLOCKING) || (fp->f_flag & O_NONBLOCK);
}

static int
counter_read(struct file *fp, struct uio *uio, struct ucred *cred, int flags)
{
	struct event_counter *counter = fp->f_data;
	uint64_t value;
	int error = 0;

	if (uio->uio_resid < sizeof(value))
		return EINVAL;
	lockmgr(&counter->lock, LK_EXCLUSIVE);
	while (counter->value == 0) {
		if (counter_nonblock(fp, flags)) {
			error = EAGAIN;
			goto done;
		}
		error = lksleep(&counter->read_wait, &counter->lock, PCATCH,
		    "evread", 0);
		if (error)
			goto done;
	}
	value = counter->semaphore ? 1 : counter->value;
	error = counter_copy(uio, &value);
	if (error == 0) {
		counter->value -= value;
		counter_advance(uio);
		wakeup(&counter->write_wait);
		KNOTE(&counter->writers, 0);
	}
done:
	lockmgr(&counter->lock, LK_RELEASE);
	return error;
}

static int
counter_write(struct file *fp, struct uio *uio, struct ucred *cred, int flags)
{
	struct event_counter *counter = fp->f_data;
	uint64_t value;
	int error;

	if (uio->uio_resid < sizeof(value))
		return EINVAL;
	error = counter_copy(uio, &value);
	if (error)
		return error;
	if (value > EVENTFD_MAX)
		return EINVAL;
	lockmgr(&counter->lock, LK_EXCLUSIVE);
	while (value > EVENTFD_MAX - counter->value) {
		if (counter_nonblock(fp, flags)) {
			error = EAGAIN;
			goto done;
		}
		error = lksleep(&counter->write_wait, &counter->lock, PCATCH,
		    "evwrite", 0);
		if (error)
			goto done;
	}
	counter->value += value;
	counter_advance(uio);
	wakeup(&counter->read_wait);
	KNOTE(&counter->readers, 0);
done:
	lockmgr(&counter->lock, LK_RELEASE);
	return error;
}

static int
counter_filter(struct file *fp, struct knote *kn)
{
	struct event_counter *counter = fp->f_data;
	struct klist *list;

	if (kn->kn_filter == EVFILT_READ) {
		kn->kn_fop = &counter_read_filter;
		list = &counter->readers;
	} else if (kn->kn_filter == EVFILT_WRITE) {
		kn->kn_fop = &counter_write_filter;
		list = &counter->writers;
	} else {
		return EOPNOTSUPP;
	}
	kn->kn_hook = (caddr_t)counter;
	lockmgr(&counter->lock, LK_EXCLUSIVE);
	knote_insert(list, kn);
	lockmgr(&counter->lock, LK_RELEASE);
	return 0;
}

static void
counter_detach(struct knote *kn)
{
	struct event_counter *counter = (void *)kn->kn_hook;
	struct klist *list = kn->kn_filter == EVFILT_READ ?
	    &counter->readers : &counter->writers;

	lockmgr(&counter->lock, LK_EXCLUSIVE);
	knote_remove(list, kn);
	lockmgr(&counter->lock, LK_RELEASE);
}

static int
counter_read_ready(struct knote *kn, long hint)
{
	struct event_counter *counter = (void *)kn->kn_hook;
	int ready;

	lockmgr(&counter->lock, LK_EXCLUSIVE);
	ready = counter->value != 0;
	kn->kn_data = ready ? sizeof(uint64_t) : 0;
	lockmgr(&counter->lock, LK_RELEASE);
	return ready;
}

static int
counter_write_ready(struct knote *kn, long hint)
{
	struct event_counter *counter = (void *)kn->kn_hook;
	int ready;

	lockmgr(&counter->lock, LK_EXCLUSIVE);
	ready = counter->value < EVENTFD_MAX;
	kn->kn_data = ready ? sizeof(uint64_t) : 0;
	lockmgr(&counter->lock, LK_RELEASE);
	return ready;
}

static int
counter_stat(struct file *fp, struct stat *st, struct ucred *cred)
{
	bzero(st, sizeof(*st));
	st->st_mode = S_IFIFO;
	return 0;
}

static int
counter_close(struct file *fp)
{
	struct event_counter *counter = fp->f_data;

	lockuninit(&counter->lock);
	kfree(counter, M_EVENTFD);
	fp->f_data = NULL;
	return 0;
}

int
sys_eventfd(struct sysmsg *sysmsg, const struct eventfd_args *uap)
{
	struct thread *td = curthread;
	struct filedesc *fdp = td->td_proc->p_fd;
	struct event_counter *counter;
	struct file *fp;
	int fd, error;

	if (uap->flags & ~(EFD_SEMAPHORE | EFD_NONBLOCK | EFD_CLOEXEC))
		return EINVAL;
	error = falloc(td->td_lwp, &fp, &fd);
	if (error)
		return error;
	counter = kmalloc(sizeof(*counter), M_EVENTFD, M_WAITOK | M_ZERO);
	lockinit(&counter->lock, "eventfd", 0, LK_CANRECURSE);
	SLIST_INIT(&counter->readers);
	SLIST_INIT(&counter->writers);
	counter->value = uap->initval;
	counter->semaphore = (uap->flags & EFD_SEMAPHORE) != 0;
	fp->f_type = DTYPE_EVENTFD;
	fp->f_flag = FREAD | FWRITE | (uap->flags & EFD_NONBLOCK);
	fp->f_ops = &counter_ops;
	fp->f_data = counter;
	if (uap->flags & EFD_CLOEXEC)
		fdp->fd_files[fd].fileflags |= UF_EXCLOSE;
	fsetfd(fdp, fp, fd);
	sysmsg->sysmsg_result = fd;
	fdrop(fp);
	return 0;
}
