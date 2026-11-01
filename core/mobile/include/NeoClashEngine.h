#ifndef NEOCLASH_ENGINE_H
#define NEOCLASH_ENGINE_H

// Implemented by core/mobile/main.go. Returned strings are freed with NCFreeString.

// Returns NULL on success, or an error message.
char *NCStart(const char *homeDir, const char *configPath, int tunFD, long long memoryLimit);

// Returns NULL on success, or an error message.
char *NCStop(void);

char *NCVersion(void);

void NCFreeString(char *value);

#endif
