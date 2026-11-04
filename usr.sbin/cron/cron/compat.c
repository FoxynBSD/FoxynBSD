/*
 * execvpe(3) for Cronie's crond (popen.c runs each job with it), which
 * this libc does not have: execvp(3) with envp as the environment.
 * crond calls it in the child it forked for the job, just before the
 * exec, so replacing environ there touches nothing else.
 */

#include <unistd.h>

extern char **environ;

int execvpe(const char *, char * const *, char * const *);

int
execvpe(const char *file, char * const argv[], char * const envp[])
{
	environ = (char **)envp;
	return (execvp(file, argv));
}
