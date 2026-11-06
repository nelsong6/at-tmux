/* Walk a stack for a crash log, in the crashed process or from outside it. */

#include <stdio.h>
#include <string.h>

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
	char		 out[1024];
	size_t		 len;
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
		len = snprintf(out, sizeof out, "  #%d %s", i,
		    SymFromAddr(proc, frame.AddrPC.Offset, &disp64, sym) ?
		    sym->Name : "?");
		if (len < sizeof out &&
		    SymGetLineFromAddr64(proc, frame.AddrPC.Offset, &disp, &line))
			snprintf(out + len, sizeof out - len, " %s:%lu",
			    line.FileName, line.LineNumber);
		emit(out, arg);
	}
	SymCleanup(proc);
}
