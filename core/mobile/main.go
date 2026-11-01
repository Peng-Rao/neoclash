// Command mobile exposes the engine package as a C library for the iOS targets.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	"github.com/pengrao/neoclash/core/mobile/engine"
)

// NCStart returns NULL on success, or an error message the caller frees with NCFreeString.
//
//export NCStart
func NCStart(homeDir, configPath *C.char, tunFD C.int, memoryLimit C.longlong) *C.char {
	err := engine.Start(engine.Options{
		HomeDir:     C.GoString(homeDir),
		ConfigPath:  C.GoString(configPath),
		TunFD:       int(tunFD),
		MemoryLimit: int64(memoryLimit),
	})
	return errorString(err)
}

// NCStop returns NULL on success, or an error message the caller frees with NCFreeString.
//
//export NCStop
func NCStop() *C.char {
	return errorString(engine.Stop())
}

// NCVersion returns the mihomo version, which the caller frees with NCFreeString.
//
//export NCVersion
func NCVersion() *C.char {
	return C.CString(engine.Version())
}

//export NCFreeString
func NCFreeString(value *C.char) {
	C.free(unsafe.Pointer(value))
}

func errorString(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

func main() {}
