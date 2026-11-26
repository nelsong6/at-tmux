/* Walk a stack for a crash log, in the crashed process or from outside it. */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "logline.h"

#include "win32-crash.h"
#include <dbghelp.h>

#pragma comment(lib, "dbghelp.lib")

void
win32_crash_stack(HANDLE proc, HANDLE thread, const CONTEXT *context,
    const char *symbols, win32_crash_line emit, void *arg)
{
	CONTEXT		 ctx = *context;
	STACKFRAME64	 frame;
	char		 symbuf[sizeof(SYMBOL_INFO) + 256];
	SYMBOL_INFO	*sym = (SYMBOL_INFO *)symbuf;
	IMAGEHLP_LINE64	 line;
	DWORD64		 disp64;
	DWORD		 disp;
	char		 at[1024];
	int		 i;

	SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME);
	SymInitialize(proc, symbols[0] != '\0' ? symbols : NULL, TRUE);

	memset(&frame, 0, sizeof frame);
	frame.AddrPC.Offset = ctx.Rip;
	frame.AddrPC.Mode = AddrModeFlat;
	frame.AddrFrame.Offset = ctx.Rbp;
	frame.AddrFrame.Mode = AddrModeFlat;
	frame.AddrStack.Offset = ctx.Rsp;
	frame.AddrStack.Mode = AddrModeFlat;
	for (i = 0; i < 32; i++) {
		if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, proc, thread, &frame,
		    &ctx, NULL, SymFunctionTableAccess64, SymGetModuleBase64,
		    NULL))
			break;
		memset(symbuf, 0, sizeof symbuf);
		sym->SizeOfStruct = sizeof(SYMBOL_INFO);
		sym->MaxNameLen = 255;
		memset(&line, 0, sizeof line);
		line.SizeOfStruct = sizeof line;
		if (SymGetLineFromAddr64(proc, frame.AddrPC.Offset, &disp, &line))
			snprintf(at, sizeof at, "%s:%lu", line.FileName,
			    line.LineNumber);
		emit(i, SymFromAddr(proc, frame.AddrPC.Offset, &disp64, sym) ?
		    sym->Name : "?", line.FileName != NULL ? at : NULL, arg);
	}
	SymCleanup(proc);
}

void
win32_crash_record(FILE *f, long pid, const char *msg, ...)
{
	logline_field	 fields[8];
	size_t		 n = 0;
	va_list		 ap;
	char		*line;

	va_start(ap, msg);
	while (n < 8 && (fields[n].key = va_arg(ap, const char *)) != NULL) {
		fields[n].value = va_arg(ap, const char *);
		n++;
	}
	va_end(ap);
	line = logline_format(logline_now(), pid, LOGLINE_ERROR, msg, fields, n);
	if (line != NULL) {
		fprintf(f, "%s\n", line);
		fflush(f);
	}
	free(line);
}
