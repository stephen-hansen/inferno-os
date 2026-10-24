#include <sys/types.h>
#include <sys/syscall.h>
#include <sys/mman.h>
#include <unistd.h>

#include "dat.h"

/*
 * x86 has a coherent instruction cache, so no flush is needed -- but
 * the JIT writes machine code into ordinary heap pages, and modern
 * kernels enforce NX there.  Mark the range executable or the first
 * jump into compiled code faults (the emu -c JIT segfaulted on
 * Linux/WSL).  Align to page boundaries as mprotect requires.
 */
int
segflush(void *a, ulong n)
{
	ulong p, b, e;
	long ps;

	ps = sysconf(_SC_PAGESIZE);
	if (ps <= 0)
		ps = 4096;
	p = (ulong) a;
	b = p & ~((ulong) ps - 1);
	e = (p + n + ps - 1) & ~((ulong) ps - 1);
	if (e <= b)
		return 0;
	mprotect((void *) b, e - b, PROT_READ | PROT_WRITE | PROT_EXEC);
	return 0;
}
